import Foundation

/// Leftovers of apps that are no longer installed. Never selected by default.
struct OrphanFinder: Sendable {
    let env: CleanerEnvironment

    static let tlds: Set<String> = ["com", "org", "net", "io", "app", "dev", "co", "me", "ai", "de", "fr", "br", "edu", "us", "uk", "jp", "ru", "cn", "tv", "xyz", "eu", "es", "it", "nl", "ca", "au", "in", "se", "ch"]
    /// System / agent / updater ids that must never be reported.
    static let denylist: [String] = [
        "com.apple", "group.com.apple", "com.junowoz.filefoundry", "com.google.keystone", "com.google.googleupdater",
        "com.microsoft.autoupdate", "com.microsoft.update", "com.microsoft.office", "com.adobe.acc", "com.adobe.crashreporter",
        "org.sparkle-project", "org.cups", "com.openssh", "com.docker", "com.jetbrains.toolbox", "net.java"
    ]

    func find(installedApps: [InstalledApp]) async throws -> [CleanupItem] {
        let fm = FileManager.default
        let installedIDs = installedApps.compactMap { $0.bundleID?.lowercased() }
        let vendors = Set(installedIDs.map(Self.vendor))
        let running = Set(env.runningBundleIDs().map { $0.lowercased() })
        var items: [CleanupItem] = []

        for folder in LibraryFolder.user {
            try Task.checkCancellation()
            let dir = env.userLibrary.appending(path: folder.relPath, directoryHint: .isDirectory)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() {
                guard let id = Self.reverseDNSID(from: name, kind: folder.kind) else { continue }
                if Self.denylist.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { continue }
                if installedIDs.contains(where: { id == $0 || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) { continue }
                if running.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { continue }
                if env.isRegisteredBundleID(id) { continue }
                let url = dir.appending(path: name)
                if case .refused = CleanerSafety.check(url, env: env) { continue }
                try Task.checkCancellation()
                let size = DiskSize.allocated(of: url)
                let sharesVendor = vendors.contains(Self.vendor(id))
                let data = [.container, .groupContainer, .applicationSupport].contains(folder.kind)
                    && (size >= 50_000_000 || DiskSize.hasNonCacheFiles(url))
                items.append(CleanupItem(
                    url: url, kind: folder.kind, confidence: sharesVendor ? .possible : .likely, allocatedSize: size,
                    needsAdmin: false, containsUserData: data, selectedByDefault: false,
                    reason: sharesVendor ? "No installed app has this id, but another app from the same vendor is installed" : "No installed app uses \(id)"))
            }
        }
        return items
    }

    static func vendor(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".") }

    /// Lowercased reverse-DNS id for an entry name, or nil when it does not look like one.
    static func reverseDNSID(from name: String, kind: LeftoverKind) -> String? {
        var n = CleanerSafety.stripExtension(name.lowercased())
        if kind == .groupContainer {
            if n.hasPrefix("group.") { n = String(n.dropFirst(6)) }
            else if let dot = n.firstIndex(of: "."), n[..<dot].count == 10, n[..<dot].allSatisfy({ $0.isLetter || $0.isNumber }) {
                n = String(n[n.index(after: dot)...])
            }
        }
        let parts = n.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, tlds.contains(String(parts[0])) else { return nil }
        let ok = parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
        return ok ? n : nil
    }
}
