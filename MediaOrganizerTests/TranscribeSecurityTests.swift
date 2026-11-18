import Foundation
import Security
import Testing
@testable import FileFoundry

private func secTemp() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "transcribe-sec-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor private func secStore(trashed: @escaping (URL) -> Void) throws -> (TranscribeStore, URL, URL) {
    let root = try secTemp(), outside = try secTemp()
    return (TranscribeStore(storageDirectory: root, apiKeyOverride: "", resumePending: false, trashItem: { trashed($0) }), root, outside)
}

// MARK: Originals

@MainActor @Test func changedOriginalIsNotTrashed() throws {
    var trashed: [String] = []
    let (store, root, outside) = try secStore { trashed.append($0.lastPathComponent) }
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let original = outside.appending(path: "voice.mp3")
    try Data("one".utf8).write(to: original)
    let folder = store.meetingsRoot.appending(path: "m1")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var m = Meeting(title: "A", sourceURL: folder.appending(path: "source.mp3"), outputDirectory: folder, originalURL: original,
                    originalFingerprint: FileFingerprint.capture(path: original.path))
    m.status = .completed
    store.meetings = [m]
    try Data("a different, longer file".utf8).write(to: original)  // changed after import
    let result = store.remove(ids: [m.id], alsoTrashOriginals: true)
    #expect(result.removed == 1 && result.originalsTrashed == 0 && result.originalsChanged == 1)
    #expect(!trashed.contains("voice.mp3"))
    #expect(store.alertMessage?.contains("Original changed; not moved") == true)
}

@MainActor @Test func replacedOriginalWithNewInodeIsNotTrashed() throws {
    var trashed: [String] = []
    let (store, root, outside) = try secStore { trashed.append($0.lastPathComponent) }
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let original = outside.appending(path: "voice.mp3")
    try Data("same".utf8).write(to: original)
    let fingerprint = FileFingerprint.capture(path: original.path)
    // Same size and path, different inode (swapped file).
    try FileManager.default.removeItem(at: original)
    try Data("same".utf8).write(to: original)
    #expect(fingerprint?.matches(path: original.path) == false)
    let folder = store.meetingsRoot.appending(path: "m1")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var m = Meeting(title: "A", sourceURL: folder.appending(path: "s.mp3"), outputDirectory: folder, originalURL: original, originalFingerprint: fingerprint)
    m.status = .completed
    store.meetings = [m]
    #expect(store.remove(ids: [m.id], alsoTrashOriginals: true).originalsTrashed == 0)
}

@MainActor @Test func originalWithoutFingerprintAndSourcePathAreNeverTrashed() throws {
    var trashed: [String] = []
    let (store, root, outside) = try secStore { trashed.append($0.lastPathComponent) }
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let victim = outside.appending(path: "victim.txt")
    try Data("precious".utf8).write(to: victim)
    var m = Meeting(title: "Legacy", sourceURL: victim, outputDirectory: store.meetingsRoot.appending(path: "x"), originalURL: victim)
    m.status = .completed
    store.meetings = [m]
    let result = store.remove(ids: [m.id], alsoTrashOriginals: true)
    #expect(result.originalsTrashed == 0 && !trashed.contains("victim.txt"))
}

@MainActor @Test func sharedOutputDirectoryIsNotTrashedWhileAnotherMeetingUsesIt() throws {
    var trashed: [String] = []
    let (store, root, outside) = try secStore { trashed.append($0.standardizedFileURL.path) }
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let folder = store.meetingsRoot.appending(path: "shared")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var a = Meeting(title: "A", sourceURL: folder.appending(path: "a.mp3"), outputDirectory: folder)
    var b = Meeting(title: "B", sourceURL: folder.appending(path: "b.mp3"), outputDirectory: folder)
    a.status = .completed; b.status = .completed
    store.meetings = [a, b]
    store.remove(ids: [a.id])
    #expect(trashed.isEmpty)
    #expect(store.meetings.map(\.id) == [b.id])
    store.remove(ids: [b.id])
    #expect(trashed == [folder.standardizedFileURL.path])
}

@Test func fingerprintCapturesRegularFilesOnly() throws {
    let dir = try secTemp()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "f"), link = dir.appending(path: "l")
    try Data("12345".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    let fp = try #require(FileFingerprint.capture(path: file.path))
    #expect(fp.size == 5 && fp.inode > 0 && fp.matches(path: file.path))
    #expect(FileFingerprint.capture(path: link.path) == nil)
    #expect(FileFingerprint.capture(path: dir.path) == nil)
}

// MARK: Importer

@Test func importerDropsOutsidePathsStripsNestedSymlinksAndDedupes() throws {
    let root = try secTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let legacy = root.appending(path: "legacy"), destination = root.appending(path: "dest")
    let folder = legacy.appending(path: "Meetings/m1")
    try fm.createDirectory(at: folder.appending(path: "deep/er"), withIntermediateDirectories: true)
    try Data("a".utf8).write(to: folder.appending(path: "source.mp3"))
    let secret = root.appending(path: "secret.txt")
    try Data("secret".utf8).write(to: secret)
    try fm.createSymbolicLink(at: folder.appending(path: "deep/er/link.txt"), withDestinationURL: secret)
    try fm.createSymbolicLink(at: folder.appending(path: "top-link"), withDestinationURL: root)

    var evil = Meeting(title: "Evil", sourceURL: URL(filePath: "/etc/hosts"), outputDirectory: URL(filePath: "/Users/victim/Documents"),
                       originalURL: URL(filePath: "/Users/victim/Desktop/x.mov"),
                       originalFingerprint: FileFingerprint(size: 1, mtimeNanos: 1, inode: 1))
    evil.status = .completed
    var good = Meeting(title: "Good", sourceURL: folder.appending(path: "source.mp3"), outputDirectory: folder)
    good.status = .completed
    var duplicate = good; duplicate.title = "Duplicate"
    try JSONEncoder().encode([good, duplicate, evil]).write(to: legacy.appending(path: "meetings.json"))

    let outcome = try ScribeLibraryImporter.performImport(legacyRoot: legacy, destinationRoot: destination)
    #expect(outcome.imported == 2 && outcome.alreadyPresent == 0 && outcome.meetings.count == 2)
    #expect(outcome.skippedLinks == 2)
    let newRoot = destination.standardizedFileURL.path
    for m in outcome.meetings {
        #expect(m.outputDirectory.hasPrefix(newRoot + "/Meetings/"))
        #expect(m.sourcePath.hasPrefix(newRoot + "/Meetings/"))
        #expect(m.originalPath == nil && m.originalFingerprint == nil)
    }
    let evilSaved = try #require(outcome.meetings.first { $0.id == evil.id })
    #expect(evilSaved.outputDirectory == destination.appending(path: "Meetings/Documents").path)
    #expect(!fm.fileExists(atPath: destination.appending(path: "Meetings/m1/deep/er/link.txt").path))
    #expect((try? fm.destinationOfSymbolicLink(atPath: destination.appending(path: "Meetings/m1/top-link").path)) == nil)
    #expect(fm.fileExists(atPath: destination.appending(path: "Meetings/m1/source.mp3").path))
    #expect(fm.fileExists(atPath: secret.path), "the link target is never touched")
}

@Test func staleStagingCleanupSkipsFoldersOfARunningImport() throws {
    let root = try secTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let legacy = root.appending(path: "legacy"), destination = root.appending(path: "dest")
    try fm.createDirectory(at: legacy.appending(path: "Meetings"), withIntermediateDirectories: true)
    try JSONEncoder().encode([Meeting]()).write(to: legacy.appending(path: "meetings.json"))
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    // A crashed run (no lock) and a live run (lock held).
    let stale = destination.appending(path: ".import-staging-stale")
    try fm.createDirectory(at: stale, withIntermediateDirectories: true)
    let live = destination.appending(path: ".import-staging-live")
    try fm.createDirectory(at: live, withIntermediateDirectories: true)
    let lockPath = destination.appending(path: ".import-staging-live.lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, 0o600)
    #expect(fd >= 0)
    defer { close(fd) }
    _ = try ScribeLibraryImporter.performImport(legacyRoot: legacy, destinationRoot: destination)
    #expect(!fm.fileExists(atPath: stale.path))
    #expect(fm.fileExists(atPath: live.path))
}

// MARK: Keychain

@Test func keychainSaveIsUpdateOrAddWithConsistentAttributes() {
    let base = ScribeKeychainStore.baseQuery(service: "svc")
    #expect(base[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(base[kSecAttrService as String] as? String == "svc")
    #expect(base[kSecAttrAccount as String] as? String == ScribeKeychainStore.account)
    let data = Data("k".utf8)
    let update = ScribeKeychainStore.updateAttributes(data: data)
    #expect(update[kSecValueData as String] as? Data == data)
    #expect(update[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    let add = ScribeKeychainStore.addQuery(service: "svc", data: data)
    for (key, value) in base { #expect("\(add[key] ?? "")" == "\(value)") }
    #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    #expect(add[kSecValueData as String] as? Data == data)
}
