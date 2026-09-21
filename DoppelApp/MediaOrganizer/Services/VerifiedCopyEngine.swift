import Foundation

enum VerifiedCopyError: LocalizedError {
    case sourceChangedDuringCopy
    case hashMismatch
    case insufficientSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .sourceChangedDuringCopy: "A origem mudou enquanto estava sendo copiada. O arquivo não foi finalizado."
        case .hashMismatch: "A cópia não passou na verificação SHA-256."
        case .insufficientSpace(let required, let available): "Espaço insuficiente: são necessários \(required) bytes e há \(available) bytes disponíveis."
        }
    }
}

actor VerifiedCopyEngine {
    private let policy = FileSystemPolicy()
    private let hasher = SHA256Hasher()

    func export(
        plan: ExportPlan,
        sources: [SourceRoot],
        destinationParent: DestinationRoot,
        progress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> (URL, ExportManifest) {
        let outputRootURL = try nextOutputRoot(parent: destinationParent.url)
        let outputRoot = try DestinationRoot(url: outputRootURL, bookmark: destinationParent.bookmark)
        try policy.validateDisjoint(sources: sources, destination: outputRoot)
        try policy.validateOutputRootDoesNotExist(outputRootURL)
        try validateFreeSpace(for: plan, at: destinationParent.url)

        try FileManager.default.createDirectory(at: outputRootURL, withIntermediateDirectories: false)
        let outputIdentity = try DestinationRootSnapshot(url: outputRootURL)
        let staging = outputRootURL.appendingPathComponent(".Media Sort-staging/\(plan.operationID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var manifest = ExportManifest(operationID: plan.operationID, createdAt: Date(), template: plan.template, sources: sources.map { $0.location.url.path }, outputRoot: outputRootURL.path, records: [])

        for (index, item) in plan.items.enumerated() {
            do {
                try Task.checkCancellation()
                let source = try policy.validateSourceFile(item.record.sourceURL, roots: sources)
                let final = try policy.validatedDestination(relativePath: item.destinationRelativePath, in: outputRoot)
                try outputIdentity.validate(url: outputRootURL)
                try policy.validateDestinationAncestors(relativePath: item.destinationRelativePath, in: outputRoot)
                if FileManager.default.fileExists(atPath: final.url.path) { throw FileSystemPolicyError.outputAlreadyExists }
                let initial = try SourceSnapshot(url: source.url)
                let sourceHash = try hasher.hash(url: source.url)
                let partial = staging.appendingPathComponent(UUID().uuidString + ".partial")
                try FileManager.default.copyItem(at: source.url, to: partial)
                let partialHash = try hasher.hash(url: partial)
                guard sourceHash == partialHash else { throw VerifiedCopyError.hashMismatch }
                let finalSourceHash = try hasher.hash(url: source.url)
                let after = try SourceSnapshot(url: source.url)
                guard initial == after, sourceHash == finalSourceHash else { throw VerifiedCopyError.sourceChangedDuringCopy }
                try FileManager.default.createDirectory(at: final.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try outputIdentity.validate(url: outputRootURL)
                try policy.validateDestinationAncestors(relativePath: item.destinationRelativePath, in: outputRoot)
                if FileManager.default.fileExists(atPath: final.url.path) { throw FileSystemPolicyError.outputAlreadyExists }
                try FileManager.default.moveItem(at: partial, to: final.url)
                let committedHash = try hasher.hash(url: final.url)
                guard committedHash == sourceHash else { throw VerifiedCopyError.hashMismatch }
                manifest.records.append(CopyRecord(id: item.id, sourceRelativePath: item.record.relativePath, destinationRelativePath: item.destinationRelativePath, sha256: committedHash, bytes: item.record.fileSize, status: .committedVerified, error: nil))
            } catch is CancellationError {
                manifest.records.append(CopyRecord(id: item.id, sourceRelativePath: item.record.relativePath, destinationRelativePath: item.destinationRelativePath, sha256: nil, bytes: item.record.fileSize, status: .cancelled, error: "Operação cancelada"))
                throw CancellationError()
            } catch {
                manifest.records.append(CopyRecord(id: item.id, sourceRelativePath: item.record.relativePath, destinationRelativePath: item.destinationRelativePath, sha256: nil, bytes: item.record.fileSize, status: .failed, error: error.localizedDescription))
            }
            await progress(index + 1, plan.items.count)
        }
        try outputIdentity.validate(url: outputRootURL)
        try ReportWriter().write(manifest: manifest, to: outputRoot)
        return (outputRootURL, manifest)
    }

    private func nextOutputRoot(parent: URL) throws -> URL {
        for index in 1...10_000 {
            let name = index == 1 ? "Media Sort — Organizado" : "Media Sort — Organizado \(index)"
            let url = parent.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw FileSystemPolicyError.outputAlreadyExists
    }

    private func validateFreeSpace(for plan: ExportPlan, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let required = Int64(Double(plan.totalBytes) * 1.05) + 100_000_000
        guard available >= required else { throw VerifiedCopyError.insufficientSpace(required: required, available: available) }
    }
}

private struct SourceSnapshot: Equatable {
    let size: Int
    let modificationDate: Date?
    let resourceIdentifier: Data?

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        size = values.fileSize ?? 0
        modificationDate = values.contentModificationDate
        resourceIdentifier = values.fileResourceIdentifier.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: false) }
    }
}

private struct DestinationRootSnapshot {
    let resourceIdentifier: Data?

    init(url: URL) throws {
        let value = try url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        resourceIdentifier = value.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: false) }
    }

    func validate(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey])
        let current = values.fileResourceIdentifier.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: false) }
        guard values.isDirectory == true, values.isSymbolicLink != true, current == resourceIdentifier else {
            throw FileSystemPolicyError.destinationOutsideScope
        }
    }
}
