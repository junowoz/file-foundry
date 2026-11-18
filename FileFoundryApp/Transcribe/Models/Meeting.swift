import Foundation

enum MeetingStatus: String, Codable {
    case ready = "Pronta"
    case preparing = "Preparando mídia"
    case uploading = "Enviando"
    case transcribing = "Transcrevendo"
    case summarizing = "Gerando resumo"
    case completed = "Concluída"
    case failed = "Falhou"
}

struct TranscriptWord: Codable, Hashable, Identifiable {
    var id: String { "\(start)-\(end)-\(text)" }
    let text: String
    let start: Int
    let end: Int
    let confidence: Double
    let speaker: String?
}

struct TranscriptUtterance: Codable, Hashable, Identifiable {
    var id: String { "\(start)-\(end)-\(speaker)" }
    let speaker: String
    let text: String
    let start: Int
    let end: Int
    let confidence: Double?
    let words: [TranscriptWord]?
}

/// Identity of a regular file taken with `lstat` at import time (size, modification time, inode).
/// A later match proves the file at that path is still the one the user imported.
struct FileFingerprint: Codable, Hashable {
    var size: Int64
    var mtimeNanos: Int64
    var inode: UInt64

    /// nil when the path is missing, is a symlink, or is not a regular file.
    static func capture(path: String) -> FileFingerprint? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let nanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FileFingerprint(size: Int64(info.st_size), mtimeNanos: nanos, inode: UInt64(info.st_ino))
    }

    func matches(path: String) -> Bool { Self.capture(path: path) == self }
}

struct Meeting: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var durationSeconds: Double
    var sourcePath: String
    /// Where the imported file lived before it was copied into the library (nil for recordings and older items).
    var originalPath: String?
    /// Fingerprint of the original taken at import. Only an original with a matching fingerprint may be trashed.
    var originalFingerprint: FileFingerprint?
    var outputDirectory: String
    var transcriptID: String?
    var speechModelUsed: String?
    var languageCode: String?
    var status: MeetingStatus
    var progress: Double
    var text: String
    var summary: String?
    var summaryError: String?
    var utterances: [TranscriptUtterance]
    var words: [TranscriptWord]
    var errorMessage: String?

    mutating func markProcessingCancelled() {
        if status == .summarizing, !text.isEmpty {
            status = .completed
            progress = 1
            errorMessage = nil
            summaryError = "Resumo cancelado. Sua transcrição está salva. Você pode gerar o resumo novamente."
        } else {
            status = .failed
            errorMessage = transcriptID == nil
                ? "Processamento cancelado. Tente novamente quando quiser."
                : "Processamento pausado. O ID remoto foi preservado e pode ser retomado sem criar cobrança duplicada."
        }
    }

    init(title: String, sourceURL: URL, outputDirectory: URL, durationSeconds: Double = 0, originalURL: URL? = nil,
         originalFingerprint: FileFingerprint? = nil) {
        id = UUID()
        self.title = title
        createdAt = Date()
        self.durationSeconds = durationSeconds
        sourcePath = sourceURL.path
        originalPath = originalURL?.path
        self.originalFingerprint = originalURL == nil ? nil : originalFingerprint
        self.outputDirectory = outputDirectory.path
        status = .ready
        progress = 0
        text = ""
        utterances = []
        words = []
    }
}
