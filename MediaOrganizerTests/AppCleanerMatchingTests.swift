import Foundation
import Testing
@testable import FileFoundry

/// Temp fake home with its own Library, /Library, application dir and fake Trash.
struct CleanerFixture {
    let root: URL, home: URL, apps: URL, sysLib: URL, trashDir: URL, outside: URL
    let env: CleanerEnvironment

    init(running: Set<String> = [], registered: Set<String> = []) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "appcleaner-" + UUID().uuidString).resolvingSymlinksInPath()
        home = root.appending(path: "home"); apps = root.appending(path: "Applications")
        sysLib = root.appending(path: "SysLibrary"); trashDir = root.appending(path: "Trash"); outside = root.appending(path: "outside")
        for d in [home.appending(path: "Library"), apps, sysLib, trashDir, outside] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let trashDir = self.trashDir
        env = CleanerEnvironment(
            homeURL: home, applicationDirs: [apps], libraryRoots: [home.appending(path: "Library"), sysLib],
            runningBundleIDs: { running }, isRegisteredBundleID: { registered.contains($0) },
            trash: { url in
                let dest = trashDir.appending(path: UUID().uuidString.prefix(6) + "-" + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            },
            recycle: { _ in nil }, trashRoots: [trashDir])
    }

    var lib: URL { home.appending(path: "Library") }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func makeApp(_ name: String, bundleID: String?, in dir: URL? = nil, extra: [String: Any] = [:]) throws -> URL {
        let app = (dir ?? apps).appending(path: name + ".app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleName": name, "CFBundleShortVersionString": "1.0"]
        if let bundleID { plist["CFBundleIdentifier"] = bundleID }
        plist.merge(extra) { $1 }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        return app
    }

    @discardableResult
    func make(_ rel: String, in base: URL? = nil, bytes: Int = 16, file: String = "data.bin") throws -> URL {
        let dir = (base ?? lib).appending(path: rel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: dir.appending(path: file))
        return dir
    }

    @discardableResult
    func touch(_ rel: String, in base: URL? = nil, bytes: Int = 16) throws -> URL {
        let url = (base ?? lib).appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    func names(_ items: [CleanupItem]) -> Set<String> { Set(items.map { $0.url.lastPathComponent }) }
}

@Test func leftoverMatchingIsPreciseForAppNamedMessages() async throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    try fx.makeApp("Messages", bundleID: "com.example.Messages")
    try fx.makeApp("Other", bundleID: "com.example.Other")
    let exact = ["Caches/com.example.Messages", "Containers/com.example.Messages", "Saved Application State/com.example.Messages.savedState",
                 "HTTPStorages/com.example.Messages", "Application Support/com.example.Messages.helper"]
    for e in exact { try fx.make(e) }
    try fx.touch("Preferences/com.example.Messages.plist")
    try fx.touch("Preferences/ByHost/com.example.Messages.ABC-123.plist")
    try fx.touch("Cookies/com.example.Messages.binarycookies")
    try fx.make("Application Support/Messages")
    // Decoys that must never match
    try fx.make("Application Support/Messages Helper")
    try fx.make("Caches/com.example.MessagesPro")
    try fx.make("Preferences/NotMessages")
    try fx.make("Projects/node_modules/eslint/messages", in: fx.home)
    try fx.make("node_modules/eslint/messages", in: fx.lib)
    try fx.make("Caches/com.example.Other")

    let installed = try await AppInventory.list(env: fx.env, includeTeamID: false)
    let app = try #require(installed.first { $0.name == "Messages" })
    let items = try await LeftoverFinder(env: fx.env).find(app: app, installedApps: installed)

    #expect(fx.names(items) == ["Messages.app", "com.example.Messages", "com.example.Messages.savedState", "com.example.Messages.helper",
                                "com.example.Messages.plist", "com.example.Messages.ABC-123.plist", "com.example.Messages.binarycookies", "Messages"])
    let byName = Dictionary(grouping: items, by: { $0.url.lastPathComponent })
    #expect(byName["Messages"]?.first(where: { $0.kind == .applicationSupport })?.confidence == .likely)
    #expect(byName["Messages"]?.first(where: { $0.kind == .applicationSupport })?.selectedByDefault == false)
    #expect(items.filter { $0.confidence == .exact }.allSatisfy { $0.selectedByDefault && !$0.needsAdmin })
    #expect(!items.contains { $0.url.path.contains("node_modules") })
}

@Test func webAppMatchesOnlyItsExactBundleID() async throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    let chromeApps = fx.apps.appending(path: "Chrome Apps.localized")
    try fx.makeApp("Messages", bundleID: "com.google.Chrome.app.abcdefgh", in: chromeApps)
    try fx.make("Application Support/Messages")
    try fx.make("Application Support/Messages Helper")
    try fx.make("Caches/com.google.Chrome.app.abcdefgh")
    try fx.make("Caches/com.google.Chrome.app.zzzzzzzz")
    try fx.make("Caches/com.google.Chrome")
    try fx.touch("Preferences/com.google.Chrome.app.abcdefgh.plist")
    try fx.make("node_modules/eslint/messages", in: fx.lib)

    let installed = try await AppInventory.list(env: fx.env, includeTeamID: false)
    let app = try #require(installed.first)
    #expect(app.isWebApp)
    let items = try await LeftoverFinder(env: fx.env).find(app: app, installedApps: installed)
    #expect(fx.names(items) == ["Messages.app", "com.google.Chrome.app.abcdefgh", "com.google.Chrome.app.abcdefgh.plist"])
}

@Test func sharedNameDisablesNameMatching() async throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    try fx.makeApp("Notes Pro", bundleID: "com.a.Notes")
    try fx.makeApp("Notes Pro Beta", bundleID: "com.b.Notes", extra: ["CFBundleName": "Notes Pro"])
    try fx.makeApp("Solo", bundleID: "com.c.Solo")
    try fx.makeApp("Solo Pro", bundleID: "com.c.Solo.Pro")
    try fx.make("Application Support/Notes Pro")
    try fx.make("Application Support/Solo")
    try fx.make("Caches/com.c.Solo.Pro")
    try fx.make("Caches/com.c.Solo")
    let installed = try await AppInventory.list(env: fx.env, includeTeamID: false)
    let notes = try #require(installed.first { $0.bundleID == "com.a.Notes" })
    let solo = try #require(installed.first { $0.bundleID == "com.c.Solo" })
    let finder = LeftoverFinder(env: fx.env)
    #expect(try await finder.find(app: notes, installedApps: installed).map(\.kind) == [.appBundle])
    // Solo: no name match (related bundle prefix installed) and the Solo.Pro cache belongs to the other app.
    let soloItems = try await finder.find(app: solo, installedApps: installed)
    #expect(fx.names(soloItems) == ["Solo.app", "com.c.Solo"])
}

@Test func groupContainerNeedsTeamIDPrefix() async throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    try fx.makeApp("Foo", bundleID: "com.example.foo")
    try fx.make("Group Containers/ABCDE12345.com.example.foo")
    try fx.make("Group Containers/ABCDE12345.com.example.foo.shared")
    try fx.make("Group Containers/group.com.example.foo")
    try fx.make("Group Containers/ZZZZZ99999.com.example.foo")
    try fx.make("Group Containers/ABCDE12345.com.other.thing")
    let base = try await AppInventory.list(env: fx.env, includeTeamID: false)
    let foo = base[0]
    let app = InstalledApp(name: foo.name, url: foo.url, bundleID: foo.bundleID, version: nil, teamID: "ABCDE12345", isApple: false,
                           isWebApp: false, isAppStore: false, isRunning: false, size: nil)
    let items = try await LeftoverFinder(env: fx.env).find(app: app, installedApps: [app])
    #expect(fx.names(items) == ["Foo.app", "ABCDE12345.com.example.foo", "ABCDE12345.com.example.foo.shared", "group.com.example.foo"])
}

@Test func systemLibraryItemsNeedAdminAndAreNotPreselected() async throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    try fx.makeApp("Foo", bundleID: "com.example.foo")
    try fx.touch("LaunchDaemons/com.example.foo.helper.plist", in: fx.sysLib)
    try fx.touch("PrivilegedHelperTools/com.example.foo.helper", in: fx.sysLib)
    try fx.make("Application Support/Foo", in: fx.sysLib)
    let installed = try await AppInventory.list(env: fx.env, includeTeamID: false)
    let items = try await LeftoverFinder(env: fx.env).find(app: installed[0], installedApps: installed).filter { $0.kind != .appBundle }
    #expect(items.count == 3)
    #expect(items.allSatisfy { $0.needsAdmin && !$0.selectedByDefault })
}

@Test func appInventoryClassifiesApps() async throws {
    let fx = try CleanerFixture(running: ["com.example.run"]); defer { fx.cleanup() }
    try fx.makeApp("Run", bundleID: "com.example.run")
    try fx.makeApp("Safari", bundleID: "com.apple.Safari")
    try fx.makeApp("Store", bundleID: "com.example.store")
    try FileManager.default.createDirectory(at: fx.apps.appending(path: "Store.app/Contents/_MASReceipt"), withIntermediateDirectories: true)
    try fx.makeApp("Shortcut", bundleID: "com.example.shortcut", extra: ["CrAppModeShortcutID": "x"])
    try fx.makeApp("Brave One", bundleID: "com.brave.Browser.app.xyz", in: fx.apps.appending(path: "Brave Browser Apps.localized"))
    let apps = try await AppInventory.list(env: fx.env, includeTeamID: false)
    func app(_ n: String) -> InstalledApp? { apps.first { $0.name == n } }
    #expect(apps.count == 5)
    #expect(app("Run")?.isRunning == true && app("Store")?.isRunning == false)
    #expect(app("Safari")?.isApple == true)
    #expect(app("Store")?.isAppStore == true)
    #expect(app("Shortcut")?.isWebApp == true && app("Brave One")?.isWebApp == true)
    #expect(app("Run")?.version == "1.0")
    let sized = await AppInventory.withSizes(apps)
    #expect(sized.allSatisfy { ($0.size ?? 0) > 0 })
}

@Test func orphanFinderReportsOnlyUnownedReverseDNSItems() async throws {
    let fx = try CleanerFixture(registered: ["com.found.app"]); defer { fx.cleanup() }
    try fx.makeApp("Installed", bundleID: "com.example.installed")
    try fx.make("Caches/com.gone.oldapp")
    try fx.make("Application Support/com.gone.oldapp.helper")
    try fx.make("Caches/com.example.installed")             // installed
    try fx.make("Caches/com.example.installed.helper")      // installed (prefix)
    try fx.make("Caches/com.example.sibling")               // same vendor, not installed: possible
    try fx.make("Caches/com.apple.thing")                   // Apple
    try fx.make("Caches/com.found.app")                     // LaunchServices knows it
    try fx.make("Caches/com.google.Keystone")               // denylisted
    try fx.make("Caches/Google")                            // not reverse DNS
    try fx.make("Caches/node_modules")
    let installed = try await AppInventory.list(env: fx.env, includeTeamID: false)
    let items = try await OrphanFinder(env: fx.env).find(installedApps: installed)
    #expect(fx.names(items) == ["com.gone.oldapp", "com.gone.oldapp.helper", "com.example.sibling"])
    #expect(items.allSatisfy { !$0.selectedByDefault && !$0.needsAdmin })
    #expect(items.first { $0.url.lastPathComponent == "com.example.sibling" }?.confidence == .possible)
    #expect(items.first { $0.url.lastPathComponent == "com.gone.oldapp" }?.confidence == .likely)
}
