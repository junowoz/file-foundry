import Foundation

enum CleanupConfidence: Int, Sendable, Codable, Comparable {
    case exact = 0, likely, possible
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum LeftoverKind: String, Sendable, Codable, CaseIterable {
    case appBundle, applicationSupport, caches, preferences, container, groupContainer, savedState, logs
    case httpStorage, webKit, cookies, launchAgent, launchDaemon, privilegedHelper, applicationScripts
}

struct CleanupItem: Sendable, Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let kind: LeftoverKind
    let confidence: CleanupConfidence
    let allocatedSize: Int64
    let needsAdmin: Bool
    let containsUserData: Bool
    let selectedByDefault: Bool
    let reason: String

    var removalRequest: RemovalRequest { RemovalRequest(url: url, size: allocatedSize, needsAdmin: needsAdmin) }
}

struct RemovalRequest: Sendable, Hashable {
    let url: URL
    let size: Int64
    let needsAdmin: Bool
    init(url: URL, size: Int64 = 0, needsAdmin: Bool = false) { self.url = url; self.size = size; self.needsAdmin = needsAdmin }
}

/// A Library subfolder the engine is allowed to look into.
struct LibraryFolder: Sendable, Hashable {
    let kind: LeftoverKind
    let relPath: String
    /// Whole-name app-name directories (lower confidence) are only searched here.
    let allowsNameMatch: Bool

    static let user: [LibraryFolder] = [
        .init(kind: .applicationSupport, relPath: "Application Support", allowsNameMatch: true),
        .init(kind: .caches, relPath: "Caches", allowsNameMatch: true),
        .init(kind: .preferences, relPath: "Preferences", allowsNameMatch: false),
        .init(kind: .preferences, relPath: "Preferences/ByHost", allowsNameMatch: false),
        .init(kind: .container, relPath: "Containers", allowsNameMatch: false),
        .init(kind: .groupContainer, relPath: "Group Containers", allowsNameMatch: false),
        .init(kind: .savedState, relPath: "Saved Application State", allowsNameMatch: false),
        .init(kind: .logs, relPath: "Logs", allowsNameMatch: true),
        .init(kind: .httpStorage, relPath: "HTTPStorages", allowsNameMatch: false),
        .init(kind: .webKit, relPath: "WebKit", allowsNameMatch: false),
        .init(kind: .cookies, relPath: "Cookies", allowsNameMatch: false),
        .init(kind: .launchAgent, relPath: "LaunchAgents", allowsNameMatch: false),
        .init(kind: .applicationScripts, relPath: "Application Scripts", allowsNameMatch: false)
    ]

    static let system: [LibraryFolder] = [
        .init(kind: .applicationSupport, relPath: "Application Support", allowsNameMatch: true),
        .init(kind: .caches, relPath: "Caches", allowsNameMatch: true),
        .init(kind: .preferences, relPath: "Preferences", allowsNameMatch: false),
        .init(kind: .launchAgent, relPath: "LaunchAgents", allowsNameMatch: false),
        .init(kind: .launchDaemon, relPath: "LaunchDaemons", allowsNameMatch: false),
        .init(kind: .privilegedHelper, relPath: "PrivilegedHelperTools", allowsNameMatch: false)
    ]
}

/// Allocated (on-disk) size helpers. Synchronous on purpose (FileManager enumerators are not async-safe);
/// they stop early when the surrounding Task is cancelled.
enum DiskSize {
    static func allocated(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        func size(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: keys) else { return 0 }
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        var total = size(url)
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return total }
        var n = 0
        for case let u as URL in e {
            n += 1
            if n % 256 == 0, Task.isCancelled { break }
            total += size(u)
        }
        return total
    }

    /// True when the folder holds files that are not obviously cache/log/preferences noise.
    static func hasNonCacheFiles(_ url: URL, limit: Int = 3000) -> Bool {
        let skipDirs: Set<String> = ["caches", "cache", "tmp", "logs", "gpucache", "code cache", "cacheddata"]
        let noise: Set<String> = ["plist", "log", "tmp", "db-wal", "db-shm", "lock", "ds_store"]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: []) else { return false }
        var n = 0
        for case let u as URL in e {
            n += 1
            if n > limit { return true } // too big to prove otherwise
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if v?.isDirectory == true {
                if skipDirs.contains(u.lastPathComponent.lowercased()) { e.skipDescendants() }
                continue
            }
            guard v?.isRegularFile == true else { continue }
            let name = u.lastPathComponent.lowercased()
            if name.hasPrefix(".com.apple.containermanagerd") || noise.contains(u.pathExtension.lowercased()) || name == ".ds_store" { continue }
            return true
        }
        return false
    }
}

enum CleanerPaths {
    /// realpath() of the deepest existing ancestor plus the remaining components, so non-existing paths resolve consistently.
    static func real(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        var tail: [String] = []
        while true {
            if let r = realpath(path, nil) {
                let s = String(cString: r); free(r)
                return tail.isEmpty ? s : (s == "/" ? "" : s) + "/" + tail.reversed().joined(separator: "/")
            }
            if path == "/" || path.isEmpty { return "/" + tail.reversed().joined(separator: "/") }
            tail.append((path as NSString).lastPathComponent)
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// Case-insensitive "p is strictly inside root".
    static func isInside(_ p: String, _ root: String) -> Bool {
        let r = root == "/" ? "/" : root.lowercased() + "/"
        return p.lowercased().hasPrefix(r) && p.count > root.count
    }

    static func relative(_ p: String, to root: String) -> [String] {
        let rest = String(p.dropFirst(root.count))
        return rest.split(separator: "/").map(String.init)
    }
}
