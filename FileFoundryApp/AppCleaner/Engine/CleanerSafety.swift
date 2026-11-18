import Foundation

enum SafetyRefusal: Sendable, Equatable {
    case homeFolder, rootFolder, systemPath, mountPoint, outsideAllowedRoots
    case protectedLocation, appleItem, fileFoundryItem

    var message: String {
        switch self {
        case .homeFolder: "The home folder can never be removed."
        case .rootFolder: "This is a root folder; only items inside it can be removed."
        case .systemPath: "System locations are never touched."
        case .mountPoint: "Mounted volumes are never touched."
        case .outsideAllowedRoots: "This path is outside the folders App Cleaner may modify."
        case .protectedLocation: "This location holds personal data (Mail, Messages, Photos, iCloud, Keychains) and is protected."
        case .appleItem: "Apple items are protected."
        case .fileFoundryItem: "File Foundry's own app and data are protected."
        }
    }
}

enum SafetyVerdict: Sendable, Equatable {
    case allowed
    case refused(SafetyRefusal)
    /// The owning app is running; quit it first.
    case appRunning(bundleID: String)

    var isAllowed: Bool { if case .allowed = self { true } else { false } }
}

/// Single gate used before every removal and put-back.
enum CleanerSafety {
    static let fileFoundryBundleID = "com.junowoz.filefoundry"
    static let systemPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private", "/etc", "/var", "/dev", "/cores", "/opt"]
    static let protectedHomeFolders = [
        "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Keychains", "Library/Photos",
        "Library/Application Support/AddressBook", "Library/Application Support/MobileSync",
        "Library/Application Support/CloudStorage", "Library/CloudStorage", "Library/Safari", "Library/Calendars"
    ]

    private enum Match { case library(rel: [String]), app(path: String), devCache(rel: [String]) }

    static func check(_ url: URL, env: CleanerEnvironment, owner: InstalledApp? = nil) -> SafetyVerdict {
        let raw = url.standardizedFileURL.path
        let real = CleanerPaths.real(url)
        let home = CleanerPaths.real(env.homeURL)
        let insideHome = real == home || CleanerPaths.isInside(real, home)

        // 1. Never the filesystem root, the home folder or a mount point.
        if real == "/" || raw == "/" { return .refused(.systemPath) }
        if real == home || raw == env.homeURL.standardizedFileURL.path { return .refused(.homeFolder) }
        let mounts = env.mountPoints.map(CleanerPaths.real)
        if mounts.contains(real) || (!insideHome && (real == "/Volumes" || CleanerPaths.isInside(real, "/Volumes"))) {
            return .refused(.mountPoint)
        }

        // 2. Root folders themselves.
        let libRoots = libraryRootPaths(env)
        let devRoots = DevCacheCatalog.rootURLs(env: env).map(CleanerPaths.real)
        let appRoots = env.applicationDirs.map(CleanerPaths.real)
        let userLibReal = CleanerPaths.real(env.userLibrary)
        var rootSet = Set((libRoots.map(\.path) + devRoots + appRoots + [userLibReal]).map { $0.lowercased() })
        if let sys = env.systemLibrary { rootSet.insert(CleanerPaths.real(sys).lowercased()) }
        for u in env.applicationDirs { rootSet.insert(u.standardizedFileURL.path.lowercased()) }
        if rootSet.contains(real.lowercased()) || rootSet.contains(raw.lowercased()) { return .refused(.rootFolder) }

        // 3. System paths (the fake homes used by tests may live under /private/var, so skip inside home).
        if !insideHome {
            let inAllowedLib = libRoots.contains { CleanerPaths.isInside(real, $0.path) }
            let inApp = appRoots.contains { CleanerPaths.isInside(real, $0) }
            if !inAllowedLib && !inApp && systemPrefixes.contains(where: { real == $0 || CleanerPaths.isInside(real, $0) }) {
                return .refused(.systemPath)
            }
        }

        // 4. Protected personal data.
        for rel in protectedHomeFolders {
            let p = CleanerPaths.real(env.homeURL.appending(path: rel))
            if real.lowercased() == p.lowercased() || CleanerPaths.isInside(real, p) { return .refused(.protectedLocation) }
        }
        let comps = real.split(separator: "/").map { $0.lowercased() }
        if comps.contains(where: { $0.hasSuffix(".photoslibrary") || $0.hasSuffix(".photolibrary") }) { return .refused(.protectedLocation) }

        // 5. Must live inside exactly one allowed root (dev cache roots first so Xcode's own cache folder is reachable).
        guard let match = match(real: real, raw: raw, env: env, libRoots: libRoots, devRoots: devRoots, appRoots: appRoots) else {
            return .refused(.outsideAllowedRoots)
        }

        // 6. Apple and File Foundry itself.
        let running = Set(env.runningBundleIDs().map { $0.lowercased() })
        var runningHit: String?
        switch match {
        case .app(let path):
            let app = AppInventory.read(appURL: URL(fileURLWithPath: path), running: running, includeTeamID: false)
            if app.isApple || path.hasPrefix("/System/") { return .refused(.appleItem) }
            if app.bundleID?.lowercased() == fileFoundryBundleID || app.url.lastPathComponent.lowercased() == "file foundry.app" { return .refused(.fileFoundryItem) }
            if app.isRunning, let b = app.bundleID { runningHit = b }
        case .library(let rel), .devCache(let rel):
            for c in rel {
                let l = c.lowercased()
                if l.hasPrefix("com.apple.") || l.hasPrefix("group.com.apple.") || l.contains(".com.apple.") || l == "com.apple" { return .refused(.appleItem) }
                if l == "file foundry" || l.contains(fileFoundryBundleID) { return .refused(.fileFoundryItem) }
            }
            if case .library = match, let first = rel.first {
                let id = stripExtension(first.lowercased())
                if let r = running.first(where: { id == $0 || id.hasPrefix($0 + ".") }) { runningHit = r }
            }
        }
        if runningHit == nil, let owner, let b = owner.bundleID, running.contains(b.lowercased()) { runningHit = b }
        if let hit = runningHit { return .appRunning(bundleID: hit) }
        return .allowed
    }

    static func stripExtension(_ n: String) -> String {
        for ext in [".plist", ".savedstate", ".binarycookies"] where n.hasSuffix(ext) { return String(n.dropLast(ext.count)) }
        return n
    }

    private static func libraryRootPaths(_ env: CleanerEnvironment) -> [(path: String, kind: LeftoverKind)] {
        var out: [(String, LeftoverKind)] = LibraryFolder.user.map { (CleanerPaths.real(env.userLibrary.appending(path: $0.relPath)), $0.kind) }
        if let sys = env.systemLibrary { out += LibraryFolder.system.map { (CleanerPaths.real(sys.appending(path: $0.relPath)), $0.kind) } }
        return out
    }

    private static func match(real: String, raw: String, env: CleanerEnvironment,
                              libRoots: [(path: String, kind: LeftoverKind)], devRoots: [String], appRoots: [String]) -> Match? {
        for r in devRoots where CleanerPaths.isInside(real, r) { return .devCache(rel: CleanerPaths.relative(real, to: r)) }
        let isAppBundle = (real as NSString).pathExtension.lowercased() == "app" && (raw as NSString).pathExtension.lowercased() == "app"
        if isAppBundle {
            for r in appRoots where CleanerPaths.isInside(real, r) {
                let rel = CleanerPaths.relative(real, to: r)
                // The .app itself, not something inside another bundle.
                if rel.dropLast().allSatisfy({ ($0 as NSString).pathExtension.lowercased() != "app" }) { return .app(path: real) }
            }
        }
        for r in libRoots where CleanerPaths.isInside(real, r.path) { return .library(rel: CleanerPaths.relative(real, to: r.path)) }
        return nil
    }
}
