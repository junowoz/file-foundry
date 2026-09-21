import Foundation

private final class EnumerationErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(URL, String)] = []

    func record(url: URL, error: any Error) {
        lock.withLock { storage.append((url, error.localizedDescription)) }
    }

    func drain() -> [(URL, String)] {
        lock.withLock { let result = storage; storage.removeAll(); return result }
    }
}

enum MediaScannerError: LocalizedError {
    case cannotEnumerate(URL)
    var errorDescription: String? {
        switch self { case .cannotEnumerate(let url): "Não foi possível enumerar a origem: \(url.path)" }
    }
}

actor MediaScanner {
    private let classifier = MediaClassifier()
    private let metadataReader = MetadataReader()
    private let hasher = SHA256Hasher()

    func scan(sources: [SourceRoot], filesystemFallback: Bool = false) async throws -> ScanSummary {
        var records: [MediaRecord] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]

        for source in sources.sorted(by: { $0.location.url.path < $1.location.url.path }) {
            let errors = EnumerationErrorCollector()
            guard let enumerator = FileManager.default.enumerator(
                at: source.location.url,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { url, error in errors.record(url: url, error: error); return true }
            ) else { throw MediaScannerError.cannotEnumerate(source.location.url) }

            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let relative = relativePath(url, root: source.location.url)
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: Set(keys))
                } catch {
                    records.append(MediaRecord(sourceRootID: source.id, sourceURL: url, relativePath: relative, filename: url.lastPathComponent, fileSize: 0, modificationDate: nil, kind: .other, captureMoment: nil, disposition: .inaccessible, note: error.localizedDescription))
                    continue
                }
                if values.isSymbolicLink == true {
                    records.append(MediaRecord(sourceRootID: source.id, sourceURL: url, relativePath: relative, filename: url.lastPathComponent, fileSize: 0, modificationDate: values.contentModificationDate, kind: .other, captureMoment: nil, disposition: .ignoredSymbolicLink, note: "Link simbólico não seguido"))
                    continue
                }
                if values.isPackage == true {
                    records.append(MediaRecord(sourceRootID: source.id, sourceURL: url, relativePath: relative, filename: url.lastPathComponent, fileSize: 0, modificationDate: values.contentModificationDate, kind: .other, captureMoment: nil, disposition: .ignoredPackage, note: "Pacote não percorrido"))
                    continue
                }
                guard values.isRegularFile == true else { continue }
                if url.lastPathComponent == ".DS_Store" || url.lastPathComponent.hasPrefix("._") {
                    records.append(MediaRecord(sourceRootID: source.id, sourceURL: url, relativePath: relative, filename: url.lastPathComponent, fileSize: Int64(values.fileSize ?? 0), modificationDate: values.contentModificationDate, kind: .other, captureMoment: nil, disposition: .ignoredSystemFile, note: "Arquivo de sistema ignorado"))
                    continue
                }
                let kind = classifier.classify(url)
                let moment = await metadataReader.captureMoment(for: url, kind: kind, filesystemFallback: filesystemFallback)
                records.append(MediaRecord(sourceRootID: source.id, sourceURL: url, relativePath: relative, filename: url.lastPathComponent, fileSize: Int64(values.fileSize ?? 0), modificationDate: values.contentModificationDate, kind: kind, captureMoment: moment))
            }
            for (url, message) in errors.drain() {
                records.append(MediaRecord(sourceRootID: source.id, sourceURL: url, relativePath: relativePath(url, root: source.location.url), filename: url.lastPathComponent, fileSize: 0, modificationDate: nil, kind: .other, captureMoment: nil, disposition: .inaccessible, note: message))
            }
        }

        let exportableIndices = records.indices.filter { records[$0].disposition == .exportable }
        let sizeBuckets = Dictionary(grouping: exportableIndices, by: { records[$0].fileSize })
        for indices in sizeBuckets.values where indices.count > 1 {
            for index in indices {
                records[index].sha256 = try hasher.hash(url: records[index].sourceURL)
            }
        }
        let groups = duplicateGroups(records)
        return ScanSummary(records: records, duplicateGroups: groups)
    }

    private func duplicateGroups(_ records: [MediaRecord]) -> [MediaDuplicateGroup] {
        let candidates = records.filter { $0.disposition == .exportable && $0.sha256 != nil }
        return Dictionary(grouping: candidates, by: { "\($0.fileSize):\($0.sha256!)" })
            .values.filter { $0.count > 1 }
            .map { records in
                let sorted = records.sorted { $0.sourceURL.path.localizedStandardCompare($1.sourceURL.path) == .orderedAscending }
                return MediaDuplicateGroup(hash: sorted[0].sha256!, canonicalID: sorted[0].id, duplicateIDs: sorted.dropFirst().map(\.id))
            }
            .sorted { $0.hash < $1.hash }
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        String(url.path.dropFirst(root.path.hasSuffix("/") ? root.path.count : root.path.count + 1))
    }
}
