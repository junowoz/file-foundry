import Foundation
import Testing
@testable import FileFoundry

@Test func serverErrorsAreTransientButAuthErrorsAreNot() {
    #expect(AssemblyAIClient.isTransient(AssemblyAIClient.ClientError.transient("x")))
    #expect(AssemblyAIClient.isTransient(URLError(.networkConnectionLost)))
    #expect(!AssemblyAIClient.isTransient(AssemblyAIClient.ClientError.api("denied")))
    #expect(!AssemblyAIClient.isTransient(URLError(.cancelled)))
}

@Test func transientFailuresAreRetriedThenSucceed() async throws {
    var calls = 0
    let value = try await AssemblyAIClient.withTransientRetries { () async throws -> Int in
        calls += 1
        if calls == 1 { throw AssemblyAIClient.ClientError.transient("busy") }
        return 42
    }
    #expect(value == 42)
    #expect(calls == 2)
}

@Test func permanentFailuresAreNotRetried() async {
    var calls = 0
    await #expect(throws: AssemblyAIClient.ClientError.self) {
        try await AssemblyAIClient.withTransientRetries { () async throws -> Int in
            calls += 1
            throw AssemblyAIClient.ClientError.api("denied")
        }
    }
    #expect(calls == 1)
}

@MainActor @Test func itemsNamedSourceGetTheirOriginalTitleBack() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "retry-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "Meetings/2026-bebe", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appending(path: "source.mp3")
    try Data("x".utf8).write(to: source)
    let original = Meeting(title: "bebe gourmet", sourceURL: source, outputDirectory: folder)
    let retried = Meeting(title: "source", sourceURL: source, outputDirectory: root.appending(path: "Meetings/2026-source"), originalURL: source)
    try JSONEncoder().encode([retried, original]).write(to: root.appending(path: "meetings.json"))
    let store = TranscribeStore(storageDirectory: root, apiKeyOverride: "", resumePending: false)
    #expect(store.meetings.map(\.title) == ["bebe gourmet", "bebe gourmet"])
}
