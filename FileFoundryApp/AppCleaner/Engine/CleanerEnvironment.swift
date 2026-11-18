import AppKit
import Foundation

/// Everything the engine touches outside of plain file reads, injectable for tests.
struct CleanerEnvironment: Sendable {
    var homeURL: URL
    /// Folders scanned for .app bundles (one level, plus "... Apps.localized" subfolders).
    var applicationDirs: [URL]
    /// [user Library, system /Library]
    var libraryRoots: [URL]
    var runningBundleIDs: @Sendable () -> Set<String>
    /// LaunchServices lookup (NSWorkspace.urlForApplication(withBundleIdentifier:) != nil).
    var isRegisteredBundleID: @Sendable (String) -> Bool
    /// Moves one item to the Trash and returns its Trash URL (FileManager.trashItem). Never deletes.
    var trash: @Sendable (URL) throws -> URL?
    /// Admin-capable recycle (NSWorkspace.recycle, prompts for authorization).
    var recycle: @Sendable (URL) async throws -> URL?
    var trashRoots: [URL]
    var mountPoints: [URL]
    var historyURL: URL

    var userLibrary: URL { libraryRoots.first ?? homeURL.appending(path: "Library", directoryHint: .isDirectory) }
    var systemLibrary: URL? { libraryRoots.count > 1 ? libraryRoots[1] : nil }

    static func defaultHistoryURL(home: URL) -> URL {
        home.appending(path: "Library/Application Support/File Foundry/App Cleaner/history.json")
    }

    init(homeURL: URL,
         applicationDirs: [URL],
         libraryRoots: [URL],
         runningBundleIDs: @escaping @Sendable () -> Set<String> = { [] },
         isRegisteredBundleID: @escaping @Sendable (String) -> Bool = { _ in false },
         trash: @escaping @Sendable (URL) throws -> URL? = CleanerEnvironment.liveTrash,
         recycle: @escaping @Sendable (URL) async throws -> URL? = CleanerEnvironment.liveRecycle,
         trashRoots: [URL]? = nil,
         mountPoints: [URL] = [],
         historyURL: URL? = nil) {
        self.homeURL = homeURL
        self.applicationDirs = applicationDirs
        self.libraryRoots = libraryRoots
        self.runningBundleIDs = runningBundleIDs
        self.isRegisteredBundleID = isRegisteredBundleID
        self.trash = trash
        self.recycle = recycle
        self.trashRoots = trashRoots ?? [homeURL.appending(path: ".Trash", directoryHint: .isDirectory)]
        self.mountPoints = mountPoints
        self.historyURL = historyURL ?? Self.defaultHistoryURL(home: homeURL)
    }

    static func live() -> CleanerEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return CleanerEnvironment(
            homeURL: home,
            applicationDirs: [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"),
                              home.appending(path: "Applications", directoryHint: .isDirectory)],
            libraryRoots: [home.appending(path: "Library", directoryHint: .isDirectory), URL(fileURLWithPath: "/Library")],
            runningBundleIDs: { Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }) },
            isRegisteredBundleID: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
            mountPoints: mounts.filter { $0.path != "/" })
    }

    static let liveTrash: @Sendable (URL) throws -> URL? = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    static let liveRecycle: @Sendable (URL) async throws -> URL? = { url in
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL?, Error>) in
            NSWorkspace.shared.recycle([url]) { newURLs, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: newURLs[url]) }
            }
        }
    }
}
