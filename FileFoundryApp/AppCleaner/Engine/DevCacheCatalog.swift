import Foundation

struct DevCache: Sendable, Identifiable, Hashable {
    var id: String { url.path }
    let tool: String
    let url: URL
    let description: String
    /// True when everything inside is regenerated automatically by the tool.
    let isPureCache: Bool
    let allocatedSize: Int64
}

/// Known regenerable developer caches ONLY. Never whole tool folders (e.g. never ~/.android: keystore, emulators).
enum DevCacheCatalog {
    struct Definition: Sendable {
        let tool: String
        let relPath: String   // relative to home
        let description: String
        let isPureCache: Bool
    }

    static let definitions: [Definition] = {
        var d: [Definition] = [
            .init(tool: "Xcode DerivedData", relPath: "Library/Developer/Xcode/DerivedData", description: "Build products and indexes; Xcode rebuilds them.", isPureCache: true),
            .init(tool: "Xcode iOS DeviceSupport", relPath: "Library/Developer/Xcode/iOS DeviceSupport", description: "Debug symbols copied from devices; copied again on next connection.", isPureCache: true),
            .init(tool: "CoreSimulator Caches", relPath: "Library/Developer/CoreSimulator/Caches", description: "Simulator dyld and runtime caches.", isPureCache: true),
            .init(tool: "Xcode Cache", relPath: "Library/Caches/com.apple.dt.Xcode", description: "Xcode download and index caches.", isPureCache: true),
            .init(tool: "Gradle", relPath: ".gradle/caches", description: "Downloaded dependencies and build caches; re-downloaded on next build.", isPureCache: true),
            .init(tool: "Android SDK cache", relPath: ".android/cache", description: "Android tooling download cache (not the keystore or emulators).", isPureCache: true),
            .init(tool: "npm", relPath: ".npm/_cacache", description: "npm package download cache.", isPureCache: true),
            .init(tool: "pnpm store", relPath: "Library/pnpm/store", description: "pnpm content store; reinstalling re-downloads packages.", isPureCache: true),
            .init(tool: "pnpm store (XDG)", relPath: ".local/share/pnpm/store", description: "pnpm content store; reinstalling re-downloads packages.", isPureCache: true),
            .init(tool: "Yarn", relPath: "Library/Caches/Yarn", description: "Yarn package cache.", isPureCache: true),
            .init(tool: "Yarn Berry", relPath: ".yarn/berry/cache", description: "Yarn Berry global package cache.", isPureCache: true),
            .init(tool: "Bun", relPath: ".bun/install/cache", description: "Bun package cache.", isPureCache: true),
            .init(tool: "pip", relPath: "Library/Caches/pip", description: "pip wheel and HTTP cache.", isPureCache: true),
            .init(tool: "uv", relPath: ".cache/uv", description: "uv package and build cache.", isPureCache: true),
            .init(tool: "CocoaPods", relPath: "Library/Caches/CocoaPods", description: "CocoaPods spec and pod download cache.", isPureCache: true),
            .init(tool: "Homebrew", relPath: "Library/Caches/Homebrew", description: "Downloaded bottles and formula metadata.", isPureCache: true),
            .init(tool: "Cargo", relPath: ".cargo/registry/cache", description: "Downloaded crate archives.", isPureCache: true),
            .init(tool: "Go build cache", relPath: "Library/Caches/go-build", description: "Compiled Go package cache.", isPureCache: true)
        ]
        for editor in ["Cursor", "Code", "Zed"] {
            let name = editor == "Code" ? "VS Code" : editor
            for sub in ["CachedData", "Cache", "GPUCache", "Code Cache"] {
                d.append(.init(tool: "\(name) \(sub)", relPath: "Library/Application Support/\(editor)/\(sub)", description: "\(name) \(sub) folder; rebuilt on next launch.", isPureCache: true))
            }
        }
        return d
    }()

    static func rootURLs(env: CleanerEnvironment) -> [URL] {
        definitions.map { env.homeURL.appending(path: $0.relPath, directoryHint: .isDirectory) }
    }

    /// Existing caches with their sizes.
    static func scan(env: CleanerEnvironment) async throws -> [DevCache] {
        var out: [DevCache] = []
        for def in definitions {
            try Task.checkCancellation()
            let url = env.homeURL.appending(path: def.relPath, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            out.append(DevCache(tool: def.tool, url: url, description: def.description, isPureCache: def.isPureCache, allocatedSize: DiskSize.allocated(of: url)))
        }
        return out
    }

    /// One request per direct child: clearing a cache trashes its CONTENTS and keeps the folder itself.
    static func removalRequests(for cache: DevCache) async throws -> [RemovalRequest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cache.url.path)) ?? []
        var out: [RemovalRequest] = []
        for n in names {
            try Task.checkCancellation()
            let u = cache.url.appending(path: n)
            out.append(RemovalRequest(url: u, size: DiskSize.allocated(of: u)))
        }
        return out
    }
}
