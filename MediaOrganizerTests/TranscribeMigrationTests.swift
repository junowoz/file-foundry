import Foundation
import Testing
@testable import FileFoundry

private func transcribeTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "transcribe-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Builds a fake Meeting Scribe container library: `meetings.json` plus `Meetings/<folder>/source.mp3`.
private func transcribeLegacyLibrary(at source: URL, outside: URL? = nil) throws -> (meetings: [Meeting], index: Data) {
    let folder = source.appending(path: "Meetings/original")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let audio = folder.appending(path: "source.mp3")
    try Data("audio fixture".utf8).write(to: audio)
    try Data("transcript".utf8).write(to: folder.appending(path: "transcript.md"))
    var meeting = Meeting(title: "Histórico", sourceURL: audio, outputDirectory: folder)
    meeting.text = "Texto preservado."
    meeting.status = .completed
    var other = Meeting(title: "Fora", sourceURL: outside ?? URL(filePath: "/Users/someone/Desktop/original.mp3"),
                        outputDirectory: folder.deletingLastPathComponent().appending(path: "missing"))
    other.status = .completed
    let index = try JSONEncoder().encode([meeting, other])
    try index.write(to: source.appending(path: "meetings.json"))
    return ([meeting, other], index)
}

@Test func transcribeRebaseRewritesOnlyPathsInsideTheOldRoot() {
    let old = URL(filePath: "/Users/x/Library/Containers/com.junowoz.MeetingScribe/Data/Library/Application Support/MeetingScribe")
    let new = URL(filePath: "/Users/x/Library/Application Support/File Foundry/Transcribe")
    #expect(ScribeLibraryImporter.rebase(old.path + "/Meetings/a/source.mp3", from: old, to: new)
        == new.path + "/Meetings/a/source.mp3")
    #expect(ScribeLibraryImporter.rebase(old.path + "/Meetings/a/../b", from: old, to: new) == new.path + "/Meetings/b")
    #expect(ScribeLibraryImporter.rebase(old.path, from: old, to: new) == new.path)
    // A sibling that merely shares the string prefix must not be rewritten.
    #expect(ScribeLibraryImporter.rebase(old.path + "-backup/Meetings/a", from: old, to: new) == nil)
    #expect(ScribeLibraryImporter.rebase("/Users/x/Desktop/original.mp3", from: old, to: new) == nil)
}

@Test func transcribeImportCopiesLibraryAndRebasesPaths() throws {
    let root = try transcribeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "legacy/MeetingScribe")
    let destination = root.appending(path: "File Foundry/Transcribe")
    let (meetings, originalIndex) = try transcribeLegacyLibrary(at: source)
    let probe = try #require(try ScribeLibraryImporter.probe(legacyRoot: source))
    #expect(probe.count == 2 && probe.bytes > 0)

    let outcome = try ScribeLibraryImporter.performImport(legacyRoot: source, destinationRoot: destination)
    #expect(outcome.imported == 2)
    let saved = try JSONDecoder().decode([Meeting].self, from: Data(contentsOf: destination.appending(path: "meetings.json")))
    #expect(saved.map(\.id) == meetings.map(\.id))
    let first = try #require(saved.first)
    #expect(first.outputDirectory == destination.appending(path: "Meetings/original").path)
    #expect(first.sourcePath == destination.appending(path: "Meetings/original/source.mp3").path)
    #expect(FileManager.default.fileExists(atPath: first.sourcePath))
    // A source outside the old root is never kept: it is re-pointed inside the new library.
    #expect(saved[1].sourcePath == destination.appending(path: "Meetings/missing/original.mp3").path)
    // The old library is untouched.
    #expect(try Data(contentsOf: source.appending(path: "meetings.json")) == originalIndex)
    #expect(FileManager.default.fileExists(atPath: source.appending(path: "Meetings/original/source.mp3").path))
    // No staging leftovers.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix(".import-staging") }
    #expect(leftovers.isEmpty)
}

@Test func transcribeImportIsIdempotent() throws {
    let root = try transcribeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "legacy")
    let destination = root.appending(path: "current")
    _ = try transcribeLegacyLibrary(at: source)
    _ = try ScribeLibraryImporter.performImport(legacyRoot: source, destinationRoot: destination)
    // A new transcription made in File Foundry in the meantime must survive a second run.
    var added = try JSONDecoder().decode([Meeting].self, from: Data(contentsOf: destination.appending(path: "meetings.json")))
    var fresh = Meeting(title: "Nova", sourceURL: destination.appending(path: "Meetings/new/a.mp3"), outputDirectory: destination.appending(path: "Meetings/new"))
    fresh.createdAt = Date().addingTimeInterval(60)
    added.append(fresh)
    try ScribeLibraryImporter.writeIndex(added, to: destination.appending(path: "meetings.json"))
    let again = try ScribeLibraryImporter.performImport(legacyRoot: source, destinationRoot: destination)
    #expect(again.imported == 0 && again.alreadyPresent == 2)
    #expect(again.meetings.count == 3)
    #expect(again.meetings.first?.title == "Nova")
}

@Test func transcribeCancelledImportLeavesNothingBehind() throws {
    let root = try transcribeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "legacy")
    let destination = root.appending(path: "current")
    _ = try transcribeLegacyLibrary(at: source)
    #expect(throws: ScribeLibraryImporter.ImportError.cancelled) {
        try ScribeLibraryImporter.performImport(legacyRoot: source, destinationRoot: destination, isCancelled: { true })
    }
    #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "meetings.json").path))
    let moved = (try? FileManager.default.contentsOfDirectory(atPath: destination.appending(path: "Meetings").path)) ?? []
    #expect(moved.isEmpty)
    let staging = (try? FileManager.default.contentsOfDirectory(atPath: destination.path))?.filter { $0.hasPrefix(".import-staging") } ?? []
    #expect(staging.isEmpty)
    // And a later run still works.
    #expect(try ScribeLibraryImporter.performImport(legacyRoot: source, destinationRoot: destination).imported == 2)
}

@Test func transcribeImportRefusesDamagedCurrentIndexAndMissingLibrary() throws {
    let root = try transcribeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "legacy")
    let destination = root.appending(path: "current")
    #expect(throws: ScribeLibraryImporter.ImportError.missingLibrary) {
        try ScribeLibraryImporter.performImport(legacyRoot: source, destinationRoot: destination)
    }
    #expect(try ScribeLibraryImporter.probe(legacyRoot: source) == nil)
    _ = try transcribeLegacyLibrary(at: source)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let damaged = Data("damaged".utf8)
    try damaged.write(to: destination.appending(path: "meetings.json"))
    #expect(throws: ScribeLibraryImporter.ImportError.unreadableCurrentIndex) {
        try ScribeLibraryImporter.performImport(legacyRoot: source, destinationRoot: destination)
    }
    #expect(try Data(contentsOf: destination.appending(path: "meetings.json")) == damaged)
}

@Test func transcribeOldHistoryWithoutOriginalPathStillDecodes() throws {
    var meeting = Meeting(title: "Antiga", sourceURL: URL(filePath: "/tmp/a.mp3"), outputDirectory: URL(filePath: "/tmp/m"), originalURL: URL(filePath: "/tmp/orig.mp3"))
    let data = try JSONEncoder().encode(meeting)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "originalPath")
    meeting = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(meeting.originalPath == nil)
}

@MainActor @Test func transcribeImportStatePersistsThroughStore() async throws {
    let root = try transcribeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "transcribe-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TranscribeStore(storageDirectory: root.appending(path: "current"), apiKeyOverride: "", resumePending: false, defaults: defaults)
    #expect(store.meetings.isEmpty)
    store.dismissLegacyOffer()
    #expect(defaults.bool(forKey: TranscribeStore.legacyDismissedKey))
    await store.refreshLegacyOffer()
    #expect(store.legacyOffer == nil)
}
