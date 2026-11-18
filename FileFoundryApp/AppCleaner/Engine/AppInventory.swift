import Foundation
import Security

struct InstalledApp: Sendable, Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let url: URL
    let bundleID: String?
    let version: String?
    let teamID: String?
    let isApple: Bool
    let isWebApp: Bool
    let isAppStore: Bool
    let isRunning: Bool
    /// Allocated bundle size; nil until computed (see AppInventory.sizeStream).
    var size: Int64?
}

enum AppInventory {
    static let webAppPrefixes = ["com.google.chrome.app.", "com.brave.browser.app.", "com.microsoft.edgemac.app."]

    /// Lists apps one level deep in each application dir, plus "... Apps.localized" folders (Chrome/Brave/Edge web apps).
    /// Sizes are not computed here (cheap call); use `sizeStream`.
    static func list(env: CleanerEnvironment, includeTeamID: Bool = true) async throws -> [InstalledApp] {
        let fm = FileManager.default
        let running = Set(env.runningBundleIDs().map { $0.lowercased() })
        var urls: [URL] = []
        for dir in env.applicationDirs {
            try Task.checkCancellation()
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() {
                let u = dir.appending(path: name)
                if name.hasSuffix(".app") { urls.append(u) }
                else if name.hasSuffix("Apps.localized") || name.hasSuffix(" Apps") {
                    for sub in ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).sorted() where sub.hasSuffix(".app") {
                        urls.append(u.appending(path: sub))
                    }
                }
            }
        }
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for u in urls where seen.insert(u.path).inserted {
            try Task.checkCancellation()
            apps.append(read(appURL: u, running: running, includeTeamID: includeTeamID))
        }
        return apps
    }

    static func read(appURL: URL, running: Set<String>, includeTeamID: Bool = true) -> InstalledApp {
        let fm = FileManager.default
        let plistURL = appURL.appending(path: "Contents/Info.plist")
        let plist = (try? Data(contentsOf: plistURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
        } ?? [:]
        let fileName = appURL.deletingPathExtension().lastPathComponent
        let name = (plist["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (plist["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fileName
        let bid = plist["CFBundleIdentifier"] as? String
        let lower = bid?.lowercased() ?? ""
        let isWeb = webAppPrefixes.contains { lower.hasPrefix($0) } || plist.keys.contains { $0.hasPrefix("CrAppModeShortcut") }
        let isApple = lower.hasPrefix("com.apple.") || appURL.path.hasPrefix("/System/")
        return InstalledApp(
            name: name, url: appURL, bundleID: bid,
            version: (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String),
            teamID: includeTeamID && !isApple ? teamID(of: appURL) : nil,
            isApple: isApple, isWebApp: isWeb,
            isAppStore: fm.fileExists(atPath: appURL.appending(path: "Contents/_MASReceipt").path),
            isRunning: !lower.isEmpty && running.contains(lower), size: nil)
    }

    static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Computes bundle sizes concurrently (max 4 at a time) and streams them as they finish. Cancelling the consumer cancels the work.
    static func sizeStream(for apps: [InstalledApp]) -> AsyncStream<(id: String, size: Int64)> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: (String, Int64).self) { group in
                    var iterator = apps.makeIterator()
                    func addNext() { if let a = iterator.next() { group.addTask { (a.id, DiskSize.allocated(of: a.url)) } } }
                    for _ in 0..<4 { addNext() }
                    while let r = await group.next() {
                        if Task.isCancelled { group.cancelAll(); break }
                        continuation.yield((id: r.0, size: r.1))
                        addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func withSizes(_ apps: [InstalledApp]) async -> [InstalledApp] {
        var sizes: [String: Int64] = [:]
        for await (id, size) in sizeStream(for: apps) { sizes[id] = size }
        return apps.map { var a = $0; a.size = sizes[a.id]; return a }
    }
}
