import Foundation

/// Pure, filesystem-free name matching for one app. Never substring-matches (except web apps' own exact bundle id).
struct LeftoverMatcher: Sendable {
    let bundleID: String?          // lowercased
    let name: String               // lowercased
    let teamID: String?            // lowercased
    let isWebApp: Bool
    private let otherIDs: [String]
    private let nameMatchAllowed: Bool

    init(app: InstalledApp, installed: [InstalledApp]) {
        let b = app.bundleID?.lowercased()
        bundleID = b
        name = app.name.lowercased()
        teamID = app.teamID?.lowercased()
        isWebApp = app.isWebApp
        let others = installed.filter { $0.url.path != app.url.path }
        otherIDs = others.compactMap { $0.bundleID?.lowercased() }
        var allowed = !app.isWebApp && name.count >= 3
        for o in others {
            if o.name.lowercased() == name { allowed = false }
            if let ob = o.bundleID?.lowercased(), let b, ob.hasPrefix(b + ".") || b.hasPrefix(ob + ".") || ob == b { allowed = false }
        }
        nameMatchAllowed = allowed
    }

    func match(name entry: String, folder: LibraryFolder) -> CleanupConfidence? {
        let n = entry.lowercased()
        let base = CleanerSafety.stripExtension(n)
        if isWebApp {
            guard let b = bundleID else { return nil }
            return n.contains(b) ? .exact : nil
        }
        if let b = bundleID {
            if matchesID(n, base, b), !claimedByOtherApp(n, base, b) { return .exact }
            if folder.kind == .groupContainer, let c = groupMatch(n, b) { return c }
        }
        if folder.allowsNameMatch, nameMatchAllowed, n == name { return .likely }
        return nil
    }

    private func matchesID(_ n: String, _ base: String, _ b: String) -> Bool {
        n == b || base == b || n.hasPrefix(b + ".")
    }

    /// "com.foo.App.Pro" belongs to another installed app, not to "com.foo.App".
    private func claimedByOtherApp(_ n: String, _ base: String, _ b: String) -> Bool {
        otherIDs.contains { o in o.count > b.count && o.hasPrefix(b + ".") && (n == o || base == o || n.hasPrefix(o + ".")) }
    }

    private func groupMatch(_ n: String, _ b: String) -> CleanupConfidence? {
        if n == "group." + b || n.hasPrefix("group." + b + ".") { return .exact }
        guard let dot = n.firstIndex(of: ".") else { return nil }
        let prefix = String(n[..<dot]), rest = String(n[n.index(after: dot)...])
        if let t = teamID { guard prefix == t else { return nil } }
        else { guard prefix.count == 10, prefix.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil } }
        if rest == b || rest.hasPrefix(b + ".") || rest.contains(b) { return .exact }
        if nameMatchAllowed, rest.replacingOccurrences(of: " ", with: "") == name.replacingOccurrences(of: " ", with: "") { return .likely }
        return nil
    }
}

struct LeftoverFinder: Sendable {
    let env: CleanerEnvironment

    /// The app bundle plus leftovers found ONLY in the listed Library subfolders. Apple apps return nothing.
    func find(app: InstalledApp, installedApps: [InstalledApp]) async throws -> [CleanupItem] {
        if app.isApple { return [] }
        let fm = FileManager.default
        let matcher = LeftoverMatcher(app: app, installed: installedApps)
        var items: [CleanupItem] = []
        var seen = Set<String>()

        let parent = app.url.deletingLastPathComponent().path
        let bundleAdmin = !fm.isWritableFile(atPath: parent)
        if !isRefused(app.url, app) {
            let size = app.size ?? DiskSize.allocated(of: app.url)
            items.append(CleanupItem(url: app.url, kind: .appBundle, confidence: .exact, allocatedSize: size, needsAdmin: bundleAdmin,
                                     containsUserData: false, selectedByDefault: !bundleAdmin, reason: "The app itself"))
            seen.insert(app.url.path)
        }

        var roots: [(URL, [LibraryFolder], Bool)] = [(env.userLibrary, LibraryFolder.user, false)]
        if let sys = env.systemLibrary { roots.append((sys, LibraryFolder.system, true)) }
        for (lib, folders, isSystem) in roots {
            for folder in folders {
                try Task.checkCancellation()
                let dir = lib.appending(path: folder.relPath, directoryHint: .isDirectory)
                guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for name in names.sorted() {
                    guard let confidence = matcher.match(name: name, folder: folder) else { continue }
                    let url = dir.appending(path: name)
                    guard seen.insert(url.path).inserted, !isRefused(url, app) else { continue }
                    try Task.checkCancellation()
                    let size = DiskSize.allocated(of: url)
                    let data = [.container, .groupContainer, .applicationSupport].contains(folder.kind)
                        && (size >= 50_000_000 || DiskSize.hasNonCacheFiles(url))
                    items.append(CleanupItem(
                        url: url, kind: folder.kind, confidence: confidence, allocatedSize: size, needsAdmin: isSystem,
                        containsUserData: data, selectedByDefault: confidence == .exact && !isSystem,
                        reason: confidence == .exact ? "Matches bundle id \(app.bundleID ?? app.name)" : "Folder named exactly \"\(app.name)\""))
                }
            }
        }
        return items
    }

    private func isRefused(_ url: URL, _ app: InstalledApp) -> Bool {
        if case .refused = CleanerSafety.check(url, env: env, owner: app) { return true }
        return false
    }
}
