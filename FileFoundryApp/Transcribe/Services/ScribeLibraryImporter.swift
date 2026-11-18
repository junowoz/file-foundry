import Foundation

/// Brings the library of the standalone Meeting Scribe app (sandboxed, so it lives inside its container)
/// into File Foundry. The original is only ever read: it is never modified, moved or deleted.
///
/// Design: folders are copied (APFS clones on the same volume) into a hidden staging directory next to the
/// destination, moved into place once every copy succeeded, and `meetings.json` is written last, atomically.
/// A cancelled or crashed run therefore leaves no partial library, and running it again is harmless:
/// folders and meeting ids that already exist are skipped.
enum ScribeLibraryImporter {
    static let legacyBundleIdentifier = "com.junowoz.MeetingScribe"
    private static let indexName = "meetings.json"
    private static let stagingPrefix = ".import-staging-"

    static var legacyRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/\(legacyBundleIdentifier)/Data/Library/Application Support/MeetingScribe", directoryHint: .isDirectory)
    }

    static var legacyPreferencesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/\(legacyBundleIdentifier)/Data/Library/Preferences/\(legacyBundleIdentifier).plist")
    }

    struct Probe: Equatable, Sendable { var count: Int; var bytes: Int64 }
    struct Outcome: Sendable {
        var imported: Int; var alreadyPresent: Int; var cloned: Bool; var meetings: [Meeting]
        /// Symbolic links found inside copied folders and left out of the library.
        var skippedLinks = 0
    }

    enum ImportError: LocalizedError, Equatable {
        case permissionDenied, missingLibrary, unreadableLegacyIndex, unreadableCurrentIndex, failed(String)
        case insufficientSpace(needed: Int64), cancelled

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "O macOS bloqueou o acesso aos dados do Meeting Scribe. Em Ajustes do Sistema > Privacidade e Segurança, permita que o File Foundry acesse dados de outros apps (ou Acesso Total ao Disco) e tente de novo."
            case .missingLibrary: "Nenhuma biblioteca do Meeting Scribe foi encontrada neste Mac."
            case .unreadableLegacyIndex: "Não foi possível ler o histórico do Meeting Scribe. Nada foi alterado."
            case .unreadableCurrentIndex: "O histórico atual não pôde ser lido, então a importação foi interrompida para preservá-lo."
            case .insufficientSpace(let needed):
                "Não há espaço livre suficiente. São necessários cerca de \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))."
            case .cancelled: "Importação cancelada. Nada foi alterado."
            case .failed(let reason): "Não foi possível copiar a biblioteca: \(reason)"
            }
        }
    }

    // MARK: Probe

    /// Counts the transcriptions and sizes the library. Returns nil when there is no old library.
    static func probe(legacyRoot: URL = legacyRoot) throws -> Probe? {
        let index = legacyRoot.appending(path: indexName)
        let data: Data
        do {
            guard FileManager.default.fileExists(atPath: index.path) else { return nil }
            data = try Data(contentsOf: index)
        } catch { throw map(error) }
        guard let meetings = try? JSONDecoder().decode([Meeting].self, from: data) else { throw ImportError.unreadableLegacyIndex }
        return Probe(count: meetings.count, bytes: allocatedSize(of: legacyRoot.appending(path: "Meetings", directoryHint: .isDirectory)))
    }

    static func legacySettingsData() -> Data? {
        guard let data = try? Data(contentsOf: legacyPreferencesURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["transcription-settings"] as? Data
    }

    // MARK: Path rewrite

    /// Rewrites `path` from `oldRoot` to `newRoot` on standardized paths (component-safe prefix match).
    /// Returns nil when the path is not inside `oldRoot`.
    static func rebase(_ path: String, from oldRoot: URL, to newRoot: URL) -> String? {
        let old = oldRoot.standardizedFileURL.path
        let target = URL(filePath: path).standardizedFileURL.path
        let new = newRoot.standardizedFileURL.path
        if target == old { return new }
        guard target.hasPrefix(old + "/") else { return nil }
        return new + target.dropFirst(old.count)
    }

    /// Rewrites a legacy record so every path points inside `newRoot`. The legacy index is untrusted input: a path
    /// that is not inside `oldRoot` (after standardizing) is dropped or replaced by a folder-name fallback, and the
    /// original-file fields are always cleared, since this app never recorded or fingerprinted that file.
    static func rewrite(_ meeting: Meeting, from oldRoot: URL, to newRoot: URL) -> Meeting {
        var result = meeting
        let folderName = URL(filePath: meeting.outputDirectory).lastPathComponent
        if let output = rebase(meeting.outputDirectory, from: oldRoot, to: newRoot) {
            result.outputDirectory = output
        } else {
            // Recorded outside the old root: fall back to the folder name, which is copied by name.
            let name = ["", "/", ".", ".."].contains(folderName) ? meeting.id.uuidString : folderName
            result.outputDirectory = newRoot.appending(path: "Meetings").appending(path: name).path
        }
        if let source = rebase(meeting.sourcePath, from: oldRoot, to: newRoot) {
            result.sourcePath = source
        } else {
            let base = URL(filePath: meeting.sourcePath).lastPathComponent
            let name = ["", "/", ".", ".."].contains(base) ? "source" : base
            result.sourcePath = URL(filePath: result.outputDirectory).appending(path: name).path
        }
        result.originalPath = nil
        result.originalFingerprint = nil
        return result
    }

    // MARK: Import

    static func performImport(
        legacyRoot: URL = legacyRoot,
        destinationRoot: URL,
        progress: @Sendable (Double) -> Void = { _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Outcome {
        let manager = FileManager.default
        let legacyMeetings = legacyRoot.appending(path: "Meetings", directoryHint: .isDirectory)
        let legacyIndex = legacyRoot.appending(path: indexName)

        let legacy: [Meeting]
        let folders: [URL]
        do {
            guard manager.fileExists(atPath: legacyIndex.path) else { throw ImportError.missingLibrary }
            let data = try Data(contentsOf: legacyIndex)
            guard let decoded = try? JSONDecoder().decode([Meeting].self, from: data) else { throw ImportError.unreadableLegacyIndex }
            legacy = decoded
            folders = ((try? manager.contentsOfDirectory(
                at: legacyMeetings, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { url in
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    return values?.isDirectory == true && values?.isSymbolicLink != true
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch let error as ImportError { throw error }
        catch { throw map(error) }

        let destinationIndex = destinationRoot.appending(path: indexName)
        let destinationMeetings = destinationRoot.appending(path: "Meetings", directoryHint: .isDirectory)
        var existing: [Meeting] = []
        if manager.fileExists(atPath: destinationIndex.path) {
            guard let data = try? Data(contentsOf: destinationIndex),
                  let decoded = try? JSONDecoder().decode([Meeting].self, from: data) else { throw ImportError.unreadableCurrentIndex }
            existing = decoded
        }
        try manager.createDirectory(at: destinationMeetings, withIntermediateDirectories: true)
        removeStaleStaging(in: destinationRoot)

        let sameVolume = onSameVolume(legacyRoot, destinationRoot)
        if !sameVolume {
            let needed = allocatedSize(of: legacyMeetings)
            let free = (try? destinationRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? .max
            if free < needed { throw ImportError.insufficientSpace(needed: needed) }
        }

        let runID = UUID().uuidString
        let staging = destinationRoot.appending(path: stagingPrefix + runID, directoryHint: .isDirectory)
        // Held for the whole run; another import's cleanup skips any staging folder whose lock is held.
        guard let lock = RunLock(url: lockURL(forStagingNamed: staging.lastPathComponent, in: destinationRoot)) else {
            throw ImportError.failed("Não foi possível reservar a área de importação.")
        }
        defer { try? manager.removeItem(at: staging); lock.release() }
        var skippedLinks = 0
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            let pending = folders.filter { !manager.fileExists(atPath: destinationMeetings.appending(path: $0.lastPathComponent).path) }
            for (offset, folder) in pending.enumerated() {
                if isCancelled() { throw ImportError.cancelled }
                let copy = staging.appending(path: folder.lastPathComponent, directoryHint: .isDirectory)
                try manager.copyItem(at: folder, to: copy)
                skippedLinks += try removeSymlinks(in: copy)
                progress(Double(offset + 1) / Double(max(pending.count, 1)) * 0.95)
            }
            if isCancelled() { throw ImportError.cancelled }
            // Point of no return: move the finished copies into place, then commit the index.
            for folder in pending {
                let destination = destinationMeetings.appending(path: folder.lastPathComponent, directoryHint: .isDirectory)
                guard !manager.fileExists(atPath: destination.path) else { continue }
                try manager.moveItem(at: staging.appending(path: folder.lastPathComponent), to: destination)
            }
        } catch let error as ImportError { throw error }
        catch { throw map(error) }

        let known = Set(existing.map(\.id))
        var seenIDs = Set<UUID>()
        let unique = legacy.filter { seenIDs.insert($0.id).inserted }
        let added = unique.filter { !known.contains($0.id) }.map { rewrite($0, from: legacyRoot, to: destinationRoot) }
        var merged = existing + added
        if !existing.isEmpty { merged.sort { $0.createdAt > $1.createdAt } }
        try writeIndex(merged, to: destinationIndex)
        progress(1)
        return Outcome(imported: added.count, alreadyPresent: unique.count - added.count, cloned: sameVolume,
                       meetings: merged, skippedLinks: skippedLinks)
    }

    static func writeIndex(_ meetings: [Meeting], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(meetings).write(to: url, options: .atomic)
    }

    // MARK: Helpers

    static func map(_ error: Error) -> ImportError {
        if let known = error as? ImportError { return known }
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code))
            || (ns.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(ns.code)) {
            return .permissionDenied
        }
        return .failed(error.localizedDescription)
    }

    private static func onSameVolume(_ a: URL, _ b: URL) -> Bool {
        let first = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let second = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let first, let second else { return false }
        return first.isEqual(second)
    }

    /// Deletes every symbolic link under `directory` (at any depth) from a staging copy. Returns how many.
    static func removeSymlinks(in directory: URL) throws -> Int {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return 0 }
        var links: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { links.append(url) }
        }
        for link in links { try manager.removeItem(at: link) }
        return links.count
    }

    private static func lockURL(forStagingNamed name: String, in root: URL) -> URL {
        root.appending(path: name + ".lock")
    }

    /// An exclusive `flock` on a lock file, taken atomically when it is created (`O_EXLOCK`).
    private struct RunLock {
        let fd: Int32
        let url: URL
        init?(url: URL) {
            let descriptor = open(url.path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, 0o600)
            guard descriptor >= 0 else { return nil }
            fd = descriptor
            self.url = url
        }
        func release() { unlink(url.path); close(fd) }
    }

    /// True unless the lock file is missing or can be locked (nobody is running that import).
    private static func isHeld(_ lock: URL) -> Bool {
        let descriptor = open(lock.path, O_RDWR | O_EXLOCK | O_NONBLOCK)
        if descriptor >= 0 { close(descriptor); return false }
        return errno != ENOENT
    }

    private static func removeStaleStaging(in root: URL) {
        let manager = FileManager.default
        let items = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])) ?? []
        for item in items where item.lastPathComponent.hasPrefix(stagingPrefix) && item.lastPathComponent.hasSuffix(".lock") {
            if !isHeld(item) { try? manager.removeItem(at: item) }
        }
        for item in items where item.lastPathComponent.hasPrefix(stagingPrefix) && !item.lastPathComponent.hasSuffix(".lock") {
            let lock = lockURL(forStagingNamed: item.lastPathComponent, in: root)
            guard !isHeld(lock) else { continue }
            try? manager.removeItem(at: item)
            try? manager.removeItem(at: lock)
        }
    }

    static func allocatedSize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
