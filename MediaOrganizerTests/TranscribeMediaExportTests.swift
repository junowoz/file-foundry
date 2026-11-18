import CoreGraphics
import PDFKit
import Foundation
import Testing
@testable import FileFoundry

private func transcribeExportFixture() -> Meeting {
    var meeting = Meeting(title: "Reunião de planejamento", sourceURL: URL(filePath: "/tmp/source.mp3"), outputDirectory: URL(filePath: "/tmp/output"))
    meeting.text = "Olá, equipe. Decidimos continuar."
    meeting.utterances = [TranscriptUtterance(speaker: "Juno", text: meeting.text, start: 1_250, end: 4_500, confidence: nil, words: nil)]
    meeting.summary = "Próximo passo: revisar a proposta."
    return meeting
}

@Test func exportsEveryUserFormat() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let meeting = transcribeExportFixture()
    for format in ScribeExportService.Format.allCases {
        let url = directory.appending(path: ScribeExportService.suggestedFilename(meeting: meeting, format: format))
        try ScribeExportService.export(meeting: meeting, format: format, to: url)
        let data = try Data(contentsOf: url)
        #expect(!data.isEmpty)
        if format == .pdf {
            #expect(String(decoding: data.prefix(5), as: UTF8.self) == "%PDF-")
        } else {
            #expect(String(decoding: data, as: UTF8.self).contains("Olá, equipe."))
        }
    }
}

@Test func paginatesLongPDFWithoutDroppingText() throws {
    var meeting = transcribeExportFixture()
    meeting.utterances = []
    meeting.text = String(repeating: "Uma linha da reunião com acentuação em português.\n", count: 450) + "MARCADOR FINAL"
    let data = try ScribeExportService.pdfData(meeting)
    let provider = try #require(CGDataProvider(data: data as CFData))
    let document = try #require(CGPDFDocument(provider))
    #expect(document.numberOfPages > 3)
    #expect(document.page(at: document.numberOfPages) != nil)
    let extracted = try #require(PDFDocument(data: data)?.string)
    #expect(extracted.contains("MARCADOR FINAL"))
    #expect(extracted.contains("acentuação em português"))
}

@Test func exportsCaptionsWithoutSpeakerLabels() throws {
    var meeting = transcribeExportFixture()
    meeting.utterances = []
    meeting.words = [TranscriptWord(text: "Olá", start: 100, end: 500, confidence: 1, speaker: nil), TranscriptWord(text: "equipe", start: 500, end: 900, confidence: 1, speaker: nil)]
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".srt")
    defer { try? FileManager.default.removeItem(at: url) }
    try ScribeExportService.export(meeting: meeting, format: .srt, to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("00:00:00,100 --> 00:00:00,900"))
    #expect(text.contains("\nOlá equipe"))
    #expect(!text.contains("\n: "))
}

@Test func rejectsUnavailableCaptionsAndEmptyTranscript() throws {
    var meeting = transcribeExportFixture()
    meeting.utterances = []
    let url = URL(filePath: "/tmp/should-not-exist-" + UUID().uuidString)
    #expect(throws: ScribeExportService.ExportError.self) { try ScribeExportService.export(meeting: meeting, format: .srt, to: url) }
    meeting.text = ""
    #expect(throws: ScribeExportService.ExportError.self) { try ScribeExportService.export(meeting: meeting, format: .txt, to: url) }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func safeFilenamesAndCaptionEscaping() {
    var meeting = transcribeExportFixture()
    meeting.title = "  Projeto / gravação: final\n"
    let filename = ScribeExportService.suggestedFilename(meeting: meeting, format: .markdown)
    #expect(!filename.contains("/"))
    #expect(!filename.contains(":"))
    #expect(!filename.contains("\n"))
    #expect(filename.hasSuffix(".md"))
    let utterance = TranscriptUtterance(speaker: "A > B", text: "<teste> & oi", start: 0, end: 2_000, confidence: nil, words: nil)
    #expect(ScribeExportService.speakerVTT([utterance]).contains("<v A &gt; B>&lt;teste&gt; &amp; oi"))
}

@Test func acceptsDocumentedMediaFormats() {
    for ext in ["m4a", "mp3", "mp4", "ogg", "flac", "wav", "webm", "opus", "MOV", "caf"] {
        #expect(ScribeMediaProcessor.supports(URL(filePath: "/tmp/media." + ext)))
    }
    #expect(!ScribeMediaProcessor.supports(URL(filePath: "/tmp/media.txt")))
    #expect(!ScribeMediaProcessor.supports(URL(string: "https://example.com/audio.mp3")!))
}

@Test func rejectsEmptyFilesAndDirectories() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp3")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "empty.mp3")
    try Data().write(to: file)
    #expect(throws: ScribeMediaProcessor.MediaError.self) { try ScribeMediaProcessor.validateImport(directory) }
    #expect(throws: ScribeMediaProcessor.MediaError.self) { try ScribeMediaProcessor.validateImport(file) }
}

@Test func uploadsOriginalWithoutNativeCodecRequirement() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // The service validates actual codec content remotely; local import preserves bytes.
    for ext in ["ogg", "flac", "webm", "mp3", "mp4"] {
        let file = directory.appending(path: "source." + ext)
        let bytes = Data("test payload for passthrough".utf8)
        try bytes.write(to: file)
        let prepared = try await ScribeMediaProcessor.prepareAudio(from: file, in: directory)
        #expect(prepared == file)
        #expect(try Data(contentsOf: prepared) == bytes)
    }
}
