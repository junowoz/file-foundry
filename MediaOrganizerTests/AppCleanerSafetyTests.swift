import Foundation
import Testing
@testable import FileFoundry

@Test func safetyRefusesRootsHomeAndSystem() throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    func verdict(_ u: URL) -> SafetyVerdict { CleanerSafety.check(u, env: fx.env) }
    #expect(verdict(fx.home) == .refused(.homeFolder))
    #expect(verdict(fx.lib.appending(path: "Application Support")) == .refused(.rootFolder))
    #expect(verdict(fx.lib.appending(path: "Caches")) == .refused(.rootFolder))
    #expect(verdict(fx.lib.appending(path: "Preferences/ByHost")) == .refused(.rootFolder))
    #expect(verdict(fx.sysLib.appending(path: "LaunchDaemons")) == .refused(.rootFolder))
    #expect(verdict(fx.apps) == .refused(.rootFolder))
    #expect(verdict(fx.home.appending(path: ".gradle/caches")) == .refused(.rootFolder))
    #expect(verdict(fx.lib) != .allowed)
    #expect(verdict(fx.home.appending(path: "Documents/thesis")) == .refused(.outsideAllowedRoots))
    let live = CleanerEnvironment.live()
    for p in ["/", "/System", "/System/Library", "/usr/bin", "/bin/ls", "/sbin", "/private/var/db", "/Users", "/Volumes"] {
        #expect(CleanerSafety.check(URL(fileURLWithPath: p), env: live) != .allowed, "\(p)")
    }
    #expect(CleanerSafety.check(live.homeURL, env: live) == .refused(.homeFolder))
    #expect(CleanerSafety.check(live.userLibrary.appending(path: "Application Support"), env: live) == .refused(.rootFolder))
}

@Test func safetyProtectsPersonalDataAppleAndFileFoundry() throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    func verdict(_ u: URL) -> SafetyVerdict { CleanerSafety.check(u, env: fx.env) }
    try fx.make("Caches/com.apple.Safari")
    try fx.make("Containers/com.apple.mail")
    try fx.make("Group Containers/group.com.apple.notes")
    try fx.make("Application Support/File Foundry/App Cleaner")
    try fx.make("Caches/com.junowoz.filefoundry")
    try fx.make("Messages/Archive", in: fx.lib)
    try fx.make("Mobile Documents/com~apple~CloudDocs", in: fx.lib)
    try fx.make("Keychains/x", in: fx.lib)
    #expect(verdict(fx.lib.appending(path: "Caches/com.apple.Safari")) == .refused(.appleItem))
    #expect(verdict(fx.lib.appending(path: "Containers/com.apple.mail")) == .refused(.appleItem))
    #expect(verdict(fx.lib.appending(path: "Group Containers/group.com.apple.notes")) == .refused(.appleItem))
    #expect(verdict(fx.lib.appending(path: "Caches/com.apple.dt.Xcode")) == .refused(.rootFolder)) // dev cache root: only its contents
    #expect(verdict(fx.lib.appending(path: "Application Support/File Foundry/App Cleaner")) == .refused(.fileFoundryItem))
    #expect(verdict(fx.lib.appending(path: "Caches/com.junowoz.filefoundry")) == .refused(.fileFoundryItem))
    #expect(verdict(fx.lib.appending(path: "Messages/Archive")) == .refused(.protectedLocation))
    #expect(verdict(fx.lib.appending(path: "Mobile Documents/com~apple~CloudDocs")) == .refused(.protectedLocation))
    #expect(verdict(fx.lib.appending(path: "Keychains/x")) == .refused(.protectedLocation))
    #expect(verdict(fx.home.appending(path: "Pictures/Photos Library.photoslibrary")) == .refused(.protectedLocation))
}

@Test func safetyRefusesAppleAndSelfAppBundlesAndAllowsOthers() throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    let safari = try fx.makeApp("Safari", bundleID: "com.apple.Safari")
    let ff = try fx.makeApp("File Foundry", bundleID: "com.junowoz.filefoundry")
    let other = try fx.makeApp("Other", bundleID: "com.example.other")
    #expect(CleanerSafety.check(safari, env: fx.env) == .refused(.appleItem))
    #expect(CleanerSafety.check(ff, env: fx.env) == .refused(.fileFoundryItem))
    #expect(CleanerSafety.check(other, env: fx.env) == .allowed)
    #expect(CleanerSafety.check(other.appending(path: "Contents"), env: fx.env) == .refused(.outsideAllowedRoots))
}

@Test func safetyResolvesSymlinksAndRefusesEscapes() throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    try fx.make("precious", in: fx.outside)
    let fm = FileManager.default
    let evil = fx.lib.appending(path: "Application Support/evil")
    try fm.createDirectory(at: evil.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: evil, withDestinationURL: fx.outside)
    #expect(CleanerSafety.check(evil, env: fx.env) != .allowed)
    #expect(CleanerSafety.check(evil.appending(path: "precious"), env: fx.env) != .allowed)
    // Symlink to the home folder is the home folder.
    let toHome = fx.lib.appending(path: "Caches/homelink")
    try fm.createDirectory(at: toHome.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: toHome, withDestinationURL: fx.home)
    #expect(CleanerSafety.check(toHome, env: fx.env) == .refused(.homeFolder))
    // `..` traversal out of an allowed root.
    let sneaky = URL(fileURLWithPath: fx.lib.path + "/Caches/../../Documents")
    #expect(CleanerSafety.check(sneaky, env: fx.env) != .allowed)
    // A normal item is fine.
    try fx.make("Caches/com.example.fine")
    #expect(CleanerSafety.check(fx.lib.appending(path: "Caches/com.example.fine"), env: fx.env) == .allowed)
}

@Test func safetyBlocksRunningApps() throws {
    let fx = try CleanerFixture(running: ["com.example.live"]); defer { fx.cleanup() }
    let app = try fx.makeApp("Live", bundleID: "com.example.live")
    try fx.make("Caches/com.example.live")
    try fx.make("Caches/com.example.live.helper")
    try fx.make("Caches/com.example.idle")
    #expect(CleanerSafety.check(app, env: fx.env) == .appRunning(bundleID: "com.example.live"))
    #expect(CleanerSafety.check(fx.lib.appending(path: "Caches/com.example.live"), env: fx.env) == .appRunning(bundleID: "com.example.live"))
    #expect(CleanerSafety.check(fx.lib.appending(path: "Caches/com.example.live.helper"), env: fx.env) == .appRunning(bundleID: "com.example.live"))
    #expect(CleanerSafety.check(fx.lib.appending(path: "Caches/com.example.idle"), env: fx.env) == .allowed)
}

@Test func trashAndPutBackRoundTrip() async throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    let a = try fx.make("Caches/com.example.a", bytes: 100)
    let b = try fx.make("Application Support/Bee", bytes: 200)
    let trash = CleanerTrash(env: fx.env)
    let report = await trash.remove([RemovalRequest(url: a, size: 100), RemovalRequest(url: b, size: 200)], label: "Uninstall Test")
    #expect(report.isCompleteSuccess && report.freedBytes == 300)
    #expect(!FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: b.path))
    let record = try #require(report.record)
    #expect(record.items.allSatisfy { $0.trashPath != nil && FileManager.default.fileExists(atPath: $0.trashPath!) })

    // History survives a restart.
    let reloaded = CleanerTrash(env: fx.env)
    #expect(await reloaded.history().first?.label == "Uninstall Test")
    #expect(FileManager.default.fileExists(atPath: fx.env.historyURL.path))

    // Occupy one original path: that item fails, the other is restored.
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    let back = await reloaded.putBack(record)
    #expect(back.restored.map(\.path) == [b.path])
    #expect(back.failures.map(\.originalPath) == [a.path])
    #expect(FileManager.default.fileExists(atPath: b.appending(path: "data.bin").path))
    #expect(await reloaded.history().first?.items.count == 1)

    // Free the path and finish.
    try FileManager.default.removeItem(at: a)
    let again = await reloaded.putBack(try #require(await reloaded.history().first))
    #expect(again.failures.isEmpty && again.restored.map(\.path) == [a.path])
    #expect(await reloaded.history().isEmpty)
}

@Test func removeReportsPartialFailuresAndNeverTouchesRefusedItems() async throws {
    let fx = try CleanerFixture(running: ["com.example.live"]); defer { fx.cleanup() }
    let ok = try fx.make("Caches/com.example.ok")
    let running = try fx.make("Caches/com.example.live")
    let apple = try fx.make("Caches/com.apple.thing")
    let missing = fx.lib.appending(path: "Caches/com.example.missing")
    let trash = CleanerTrash(env: fx.env)
    let report = await trash.remove([RemovalRequest(url: apple), RemovalRequest(url: running), RemovalRequest(url: missing),
                                     RemovalRequest(url: fx.lib.appending(path: "Caches")), RemovalRequest(url: ok)], label: "Mixed")
    #expect(report.outcomes.count == 5)
    #expect(report.outcomes[0].status == .blocked(.refused(.appleItem)))
    #expect(report.outcomes[1].status == .blocked(.appRunning(bundleID: "com.example.live")))
    if case .failed = report.outcomes[2].status {} else { Issue.record("missing item should fail, got \(report.outcomes[2].status)") }
    #expect(report.outcomes[3].status == .blocked(.refused(.rootFolder)))
    #expect(report.outcomes[4].succeeded)
    #expect(FileManager.default.fileExists(atPath: apple.path) && FileManager.default.fileExists(atPath: running.path))
    #expect(report.record?.items.count == 1)
}

@Test func putBackRefusesTamperedHistory() async throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    let victim = try fx.make("precious", in: fx.outside)
    let trash = CleanerTrash(env: fx.env)
    // Record pointing at a path that is not inside the Trash.
    let forged = TrashRecord(id: UUID(), date: Date(), label: "forged",
                             items: [TrashItemRecord(originalPath: fx.lib.appending(path: "Caches/x").path, trashPath: victim.path, size: 1)])
    let r = await trash.putBack(forged)
    #expect(r.restored.isEmpty && r.failures.count == 1)
    #expect(FileManager.default.fileExists(atPath: victim.path))
}

@Test func devCacheCatalogNeverReturnsDotAndroid() async throws {
    let fx = try CleanerFixture(); defer { fx.cleanup() }
    try fx.make(".android/cache/dl", in: fx.home)
    try fx.touch(".android/debug.keystore", in: fx.home)
    try fx.make(".android/avd/Pixel", in: fx.home)
    try fx.make(".npm/_cacache/content", in: fx.home, bytes: 4096)
    try fx.make("Library/Developer/Xcode/DerivedData/App-abc", in: fx.home)
    try fx.make("Library/Application Support/Cursor/GPUCache", in: fx.home)
    try fx.make("Library/Application Support/Cursor/User", in: fx.home)   // settings: not a cache
    try fx.make("Library/Caches/com.apple.dt.Xcode/x", in: fx.home)

    let caches = try await DevCacheCatalog.scan(env: fx.env)
    let paths = Set(caches.map { $0.url.path })
    #expect(!paths.contains(fx.home.appending(path: ".android").path))
    #expect(paths == Set([".android/cache", ".npm/_cacache", "Library/Developer/Xcode/DerivedData",
                          "Library/Application Support/Cursor/GPUCache", "Library/Caches/com.apple.dt.Xcode"].map { fx.home.appending(path: $0).path }))
    #expect(caches.allSatisfy { $0.allocatedSize > 0 && !$0.description.isEmpty })

    // Safety: the keystore/emulators and the cache roots are refused; contents of a cache are allowed.
    #expect(CleanerSafety.check(fx.home.appending(path: ".android"), env: fx.env) != .allowed)
    #expect(CleanerSafety.check(fx.home.appending(path: ".android/debug.keystore"), env: fx.env) != .allowed)
    #expect(CleanerSafety.check(fx.home.appending(path: ".android/avd/Pixel"), env: fx.env) != .allowed)
    #expect(CleanerSafety.check(fx.home.appending(path: ".android/cache"), env: fx.env) == .refused(.rootFolder))
    #expect(CleanerSafety.check(fx.home.appending(path: ".android/cache/dl"), env: fx.env) == .allowed)
    #expect(CleanerSafety.check(fx.home.appending(path: "Library/Caches/com.apple.dt.Xcode/x"), env: fx.env) == .allowed)

    // Clearing keeps the folder.
    let android = try #require(caches.first { $0.url.lastPathComponent == "cache" })
    let reqs = try await DevCacheCatalog.removalRequests(for: android)
    #expect(reqs.map(\.url.lastPathComponent) == ["dl"])
    let report = await CleanerTrash(env: fx.env).remove(reqs, label: "Clear Android cache")
    #expect(report.isCompleteSuccess)
    #expect(FileManager.default.fileExists(atPath: android.url.path))
    #expect(FileManager.default.fileExists(atPath: fx.home.appending(path: ".android/debug.keystore").path))
}

@Test func volumeInfoReportsRoot() {
    let vols = VolumeInfo.all()
    let root = vols.first { $0.url.path == "/" }
    #expect(root != nil && (root?.total ?? 0) > 0 && (root?.availableForImportantUsage ?? 0) >= (root?.available ?? 1) - 1)
}
