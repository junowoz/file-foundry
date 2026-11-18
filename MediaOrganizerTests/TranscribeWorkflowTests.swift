import Foundation
import Testing
@testable import FileFoundry

@Test func oldHistoryDecodesWithoutSummaryError() throws {
    let meeting = Meeting(title: "Reunião", sourceURL: URL(filePath: "/tmp/audio.mp3"), outputDirectory: URL(filePath: "/tmp/meeting"))
    let data = try JSONEncoder().encode(meeting)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "summaryError")
    let restored = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.id == meeting.id)
    #expect(restored.summaryError == nil)
}

@Test func summaryFailureRemainsSeparateFromTranscript() throws {
    var meeting = Meeting(title: "Reunião", sourceURL: URL(filePath: "/tmp/audio.mp3"), outputDirectory: URL(filePath: "/tmp/meeting"))
    meeting.text = "Decidimos lançar na sexta."
    meeting.summaryError = "Sem acesso ao resumo."
    meeting.status = .completed
    let restored = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
    #expect(restored.text == meeting.text)
    #expect(restored.summary == nil)
    #expect(restored.summaryError == meeting.summaryError)
    #expect(restored.status == .completed)
}

@Test func inaccessibleSummaryHasRecoveryWithoutRawPayload() {
    let raw = #"{"metadata":{"errors":["Your account does not have access to this LLM Gateway model"]},"request_id":"private-id"}"#
    let message = AssemblyAIClient.errorMessage(statusCode: 400, data: Data(raw.utf8))
    #expect(message.contains("The transcript is still available"))
    #expect(message.contains("try generating the summary again"))
    #expect(!message.contains("private-id"))
}

@Test func authenticationAndRateLimitsHaveRecovery() {
    #expect(AssemblyAIClient.errorMessage(statusCode: 401, data: Data()).contains("API key"))
    #expect(AssemblyAIClient.errorMessage(statusCode: 429, data: Data()).contains("Wait"))
    #expect(AssemblyAIClient.errorMessage(statusCode: 503, data: Data()).contains("Try again"))
}

@MainActor @Test func failedTrashPreservesHistory() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TranscribeStore(storageDirectory: directory, apiKeyOverride: "", resumePending: false,
                         trashItem: { _ in throw CocoaError(.fileWriteNoPermission) })
    let folder = store.meetingsRoot.appending(path: "m1")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let meeting = Meeting(title: "Preservar", sourceURL: folder.appending(path: "audio.mp3"), outputDirectory: folder)
    store.meetings = [meeting]
    store.selection = meeting.id
    store.remove(meeting, deleteFiles: true)
    #expect(store.meetings.count == 1)
    #expect(store.selection == meeting.id)
    #expect(store.alertMessage?.contains("history was kept") == true)
}

@MainActor @Test func renameTrimsAndRejectsBlankTitle() {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TranscribeStore(storageDirectory: directory, apiKeyOverride: "", resumePending: false)
    let meeting = Meeting(title: "Original", sourceURL: directory.appending(path: "audio.mp3"), outputDirectory: directory)
    store.meetings = [meeting]
    store.rename(meeting, title: "  \n ")
    #expect(store.meetings.first?.title == "Original")
    store.rename(meeting, title: "  Novo nome \n")
    #expect(store.meetings.first?.title == "Novo nome")
}

@MainActor @Test func queueRunsInOrderWithoutCancellingActiveJob() async {
    let store = TranscribeStore(storageDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), apiKeyOverride: "", resumePending: false)
    var events: [Int] = []
    store.enqueue {
        events.append(1)
        await Task.yield()
        #expect(!Task.isCancelled)
        events.append(2)
    }
    store.enqueue { events.append(3) }
    #expect(store.queuedCount == 1)
    for _ in 0..<100 where store.isBusy { await Task.yield() }
    #expect(events == [1, 2, 3])
    #expect(store.queuedCount == 0)
}

@MainActor @Test func missingKeyDoesNotCreateOrQueueMeeting() {
    let store = TranscribeStore(storageDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), apiKeyOverride: " \n", resumePending: false)
    store.importMedia([URL(filePath: "/tmp/test.mp3")])
    #expect(store.meetings.isEmpty)
    #expect(store.queuedCount == 0)
    #expect(!store.isBusy)
    #expect(store.alertMessage?.contains("API key") == true)
}

@MainActor @Test func damagedHistoryIsNeverOverwritten() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = Data("damaged but recoverable history".utf8)
    let index = directory.appending(path: "meetings.json")
    try original.write(to: index)
    let store = TranscribeStore(storageDirectory: directory, apiKeyOverride: "", resumePending: false)
    store.enqueue {}
    #expect(!store.isBusy)
    #expect(store.queuedCount == 0)
    #expect(try Data(contentsOf: index) == original)
    #expect(store.alertMessage?.contains("was kept") == true)
}


@MainActor @Test func missingOutputDirectoryCanBeRemovedFromHistory() {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TranscribeStore(storageDirectory: directory, apiKeyOverride: "", resumePending: false)
    let meeting = Meeting(title: "Antiga", sourceURL: directory.appending(path: "audio.mp3"), outputDirectory: directory.appending(path: "missing"))
    store.meetings = [meeting]
    store.selection = meeting.id
    store.remove(meeting, deleteFiles: true)
    #expect(store.meetings.isEmpty)
    #expect(store.selection == nil)
    #expect(store.alertMessage == nil)
}

@Test func cancelledSummaryKeepsCompletedTranscript() {
    var meeting = Meeting(title: "Reunião", sourceURL: URL(filePath: "/tmp/audio.mp3"), outputDirectory: URL(filePath: "/tmp/meeting"))
    meeting.status = .summarizing
    meeting.text = "Texto já salvo."
    meeting.transcriptID = "remote-id"
    meeting.markProcessingCancelled()
    #expect(meeting.status == .completed)
    #expect(meeting.text == "Texto já salvo.")
    #expect(meeting.transcriptID == "remote-id")
    #expect(meeting.errorMessage == nil)
    #expect(meeting.summaryError?.contains("canceled") == true)
}

@Test func cancelledTranscriptionKeepsRemoteIDForResume() {
    var meeting = Meeting(title: "Reunião", sourceURL: URL(filePath: "/tmp/audio.mp3"), outputDirectory: URL(filePath: "/tmp/meeting"))
    meeting.status = .transcribing
    meeting.transcriptID = "remote-id"
    meeting.markProcessingCancelled()
    #expect(meeting.status == .failed)
    #expect(meeting.transcriptID == "remote-id")
    #expect(meeting.errorMessage?.contains("resume") == true)
}

@MainActor private func transcribeBatchStore(trashed: @escaping (URL) -> Void = { _ in }) throws -> (TranscribeStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = TranscribeStore(storageDirectory: directory, apiKeyOverride: "", resumePending: false,
                         trashItem: { trashed($0) })
    return (store, directory)
}

@MainActor private func transcribeMakeMeeting(_ title: String, in root: URL, status: MeetingStatus) throws -> Meeting {
    let folder = root.appending(path: "Meetings").appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var meeting = Meeting(title: title, sourceURL: folder.appending(path: "a.mp3"), outputDirectory: folder)
    meeting.status = status
    return meeting
}

@MainActor @Test func batchRemoveTrashesCompletedAndSkipsInFlight() throws {
    var trashed: [URL] = []
    let (store, root) = try transcribeBatchStore { trashed.append($0) }
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try transcribeMakeMeeting("A", in: root, status: .completed)
    let b = try transcribeMakeMeeting("B", in: root, status: .failed)
    let c = try transcribeMakeMeeting("C", in: root, status: .transcribing)
    store.meetings = [a, b, c]
    store.selection = a.id
    #expect(store.completedMeetings.count == 1)
    #expect(store.failedMeetings.count == 1)
    #expect(store.canDelete(c), "idle store: a stuck in-flight meeting can be removed")
    store.isBusy = true
    #expect(store.canDelete(a) && store.canDelete(b) && !store.canDelete(c))
    let result = store.remove(ids: [a.id, b.id, c.id])
    #expect(result == .init(removed: 2, skipped: 1, failed: 0))
    #expect(trashed.count == 2)
    #expect(store.meetings.map(\.id) == [c.id])
    #expect(store.selection == c.id)
    #expect(store.notice?.text.contains("2 transcripts moved to the Trash") == true)
    let saved = try Data(contentsOf: root.appending(path: "meetings.json"))
    #expect(try JSONSerialization.jsonObject(with: saved) is [Any])
}

@MainActor @Test func batchRemoveKeepsItemsWhoseTrashFails() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TranscribeStore(storageDirectory: directory, apiKeyOverride: "", resumePending: false,
                         trashItem: { _ in throw CocoaError(.fileWriteNoPermission) })
    let a = try transcribeMakeMeeting("A", in: directory, status: .completed)
    store.meetings = [a]
    let result = store.remove(ids: [a.id])
    #expect(result == .init(removed: 0, skipped: 0, failed: 1))
    #expect(store.meetings.count == 1)
    #expect(store.alertMessage != nil)
}

@MainActor @Test func trashRefusesFoldersOutsideMeetingsRoot() throws {
    var trashed: [URL] = []
    let (store, root) = try transcribeBatchStore { trashed.append($0) }
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appending(path: "Elsewhere")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let link = store.meetingsRoot.appending(path: "link")
    try FileManager.default.createDirectory(at: store.meetingsRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(!store.isSafeToTrash(outside))
    #expect(!store.isSafeToTrash(store.meetingsRoot))
    #expect(!store.isSafeToTrash(link))
    #expect(!store.isSafeToTrash(store.meetingsRoot.appending(path: "../Elsewhere")))
    var m = Meeting(title: "X", sourceURL: outside.appending(path: "a.mp3"), outputDirectory: outside)
    m.status = .completed
    store.meetings = [m]
    store.remove(ids: [m.id])
    #expect(trashed.isEmpty)
    #expect(store.meetings.isEmpty)
}

// MARK: Delete original file option

@MainActor private func transcribeStoreWithOriginals(trashed: @escaping (URL) -> Void) throws -> (TranscribeStore, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "transcribe-orig-" + UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appending(path: "transcribe-outside-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let store = TranscribeStore(storageDirectory: root, apiKeyOverride: "", resumePending: false, trashItem: { trashed($0) })
    return (store, root, outside)
}

@MainActor @Test func deleteTrashesOriginalOutsideLibraryOnlyWhenRequested() throws {
    var trashed: [String] = []
    let (store, root, outside) = try transcribeStoreWithOriginals { trashed.append($0.standardizedFileURL.path) }
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let original = outside.appending(path: "gravacao.mp3")
    try Data("x".utf8).write(to: original)
    func meeting() throws -> Meeting {
        let folder = store.meetingsRoot.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: folder.appending(path: "source.mp3"))
        var m = Meeting(title: "A", sourceURL: folder.appending(path: "source.mp3"), outputDirectory: folder, originalURL: original,
                    originalFingerprint: FileFingerprint.capture(path: original.path))
        m.status = .completed
        return m
    }
    let off = try meeting()
    store.meetings = [off]
    store.remove(ids: [off.id])
    #expect(trashed.count == 1)  // only the folder
    #expect(!trashed.contains(original.standardizedFileURL.path))

    trashed = []
    let on = try meeting()
    store.meetings = [on]
    let result = store.remove(ids: [on.id], alsoTrashOriginals: true)
    #expect(result.originalsTrashed == 1 && result.removed == 1)
    #expect(trashed.count == 2)
    #expect(trashed.contains(original.standardizedFileURL.path))
    #expect(store.notice?.text == "1 transcript and 1 original moved to the Trash")
}

@MainActor @Test func deleteNeverTrashesSymlinksDirectoriesOrFilesInsideLibrary() throws {
    var trashed: [String] = []
    let (store, root, outside) = try transcribeStoreWithOriginals { trashed.append($0.lastPathComponent) }
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let real = outside.appending(path: "real.mp3")
    try Data("x".utf8).write(to: real)
    let link = outside.appending(path: "link.mp3")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let directory = outside.appending(path: "Pasta.mp3")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let inside = store.meetingsRoot.appending(path: "m/inside.mp3")
    try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: inside)
    #expect(store.isSafeOriginalToTrash(real.path))
    #expect(!store.isSafeOriginalToTrash(link.path))
    #expect(!store.isSafeOriginalToTrash(directory.path))
    #expect(!store.isSafeOriginalToTrash(inside.path))
    #expect(!store.isSafeOriginalToTrash(outside.appending(path: "missing.mp3").path))
    #expect(!store.isSafeOriginalToTrash(""))
    _ = trashed
}

@MainActor @Test func deleteKeepsOriginalStillUsedByAnotherTranscription() throws {
    var trashed: [String] = []
    let (store, root, outside) = try transcribeStoreWithOriginals { trashed.append($0.lastPathComponent) }
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let original = outside.appending(path: "shared.mp3")
    try Data("x".utf8).write(to: original)
    var a = Meeting(title: "A", sourceURL: original, outputDirectory: store.meetingsRoot.appending(path: "a"), originalURL: original,
                    originalFingerprint: FileFingerprint.capture(path: original.path))
    var b = Meeting(title: "B", sourceURL: original, outputDirectory: store.meetingsRoot.appending(path: "b"), originalURL: original,
                    originalFingerprint: FileFingerprint.capture(path: original.path))
    a.status = .completed; b.status = .completed
    store.meetings = [a, b]
    let result = store.remove(ids: [a.id], alsoTrashOriginals: true)
    #expect(result.originalsTrashed == 0)
    #expect(!trashed.contains("shared.mp3"))
    let last = store.remove(ids: [b.id], alsoTrashOriginals: true)
    #expect(last.originalsTrashed == 1)
    #expect(trashed == ["shared.mp3"])
}

@MainActor @Test func deleteToastPluralizesOriginals() throws {
    let (store, root, outside) = try transcribeStoreWithOriginals { _ in }
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    var metas: [Meeting] = []
    for index in 0..<3 {
        let original = outside.appending(path: "o\(index).mp3")
        try Data("x".utf8).write(to: original)
        var m = Meeting(title: "M\(index)", sourceURL: original, outputDirectory: store.meetingsRoot.appending(path: "m\(index)"), originalURL: original,
                    originalFingerprint: FileFingerprint.capture(path: original.path))
        m.status = .completed
        metas.append(m)
    }
    store.meetings = metas
    store.remove(ids: Set(metas.map(\.id)), alsoTrashOriginals: true)
    #expect(store.notice?.text == "3 transcripts and 3 originals moved to the Trash")
}
