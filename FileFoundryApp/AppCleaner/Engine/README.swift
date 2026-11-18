// App Cleaner engine (no UI). All types are Sendable values, APIs are async + cancellable (they throw CancellationError).
// Everything is driven by a `CleanerEnvironment` (use `.live()` in the app; tests inject a fake home).
//
//   let env = CleanerEnvironment.live()
//
// 1. Inventory
//    let apps = try await AppInventory.list(env: env)               // [InstalledApp], sizes nil (fast)
//    for await (id, size) in AppInventory.sizeStream(for: apps) {}   // lazy, concurrent; id == InstalledApp.id (path)
//    InstalledApp: name, url, bundleID, version, teamID, isApple, isWebApp, isAppStore, isRunning, size
//
// 2. Uninstall one app
//    let items = try await LeftoverFinder(env: env).find(app: app, installedApps: apps)
//    CleanupItem: url, kind (LeftoverKind), confidence (.exact/.likely), allocatedSize, needsAdmin,
//                 containsUserData (warn before removing), selectedByDefault, reason. The .appBundle item is included.
//    Apple apps return []. Only fixed ~/Library and /Library subfolders are searched; never Spotlight, never substrings.
//
// 3. Orphans (leftovers of apps no longer installed)
//    let orphans = try await OrphanFinder(env: env).find(installedApps: apps)   // same CleanupItem, never selectedByDefault,
//                                                                                // confidence .likely or .possible (same vendor installed)
// 4. Developer caches
//    let caches = try await DevCacheCatalog.scan(env: env)           // [DevCache] existing only: tool, url, description, isPureCache, allocatedSize
//    let reqs = try await DevCacheCatalog.removalRequests(for: cache) // CONTENTS of the folder; the folder itself stays
//
// 5. Safety gate (called by CleanerTrash before every removal; call it in the UI to disable rows)
//    CleanerSafety.check(url, env: env, owner: app?) -> SafetyVerdict
//      .allowed | .refused(SafetyRefusal; `.message` is user-readable) | .appRunning(bundleID:) (quit the app first)
//
// 6. Removal (always the Trash, recoverable) and undo
//    let trash = CleanerTrash(env: env)                              // actor; history at
//                                                                    // ~/Library/Application Support/File Foundry/App Cleaner/history.json
//    let report = await trash.remove(items, label: "Uninstall Foo")  // also remove(_ [RemovalRequest], label:)
//      report.outcomes [ItemOutcome(url, status: .trashed/.blocked/.failed/.cancelled)], report.record, report.freedBytes, report.failures
//    needsAdmin items go through NSWorkspace.recycle (macOS asks for admin authorization).
//    await trash.history() -> [TrashRecord] (newest first, max 100: id, date, label, items[originalPath, trashPath, size])
//    let back = await trash.putBack(record)                          // PutBackReport(restored: [URL], failures: [PutBackFailure(originalPath, reason)])
//    await trash.forget(record)
//
// 7. Disks
//    VolumeInfo.all() -> [VolumeInfo]  (name, url, total, available, availableForImportantUsage, purgeable, used, isExternal; "/" first)
//
// Suggested flow: list apps -> user picks app -> find leftovers -> show items (preselect `selectedByDefault`, warn on
// `containsUserData` / `needsAdmin`, block rows whose verdict is .appRunning until the app quits) -> trash.remove -> offer putBack.
