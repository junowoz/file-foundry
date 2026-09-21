import Foundation

enum MediaKind: String, Codable, CaseIterable, Sendable {
    case photo = "Foto"
    case rawPhoto = "RAW"
    case video = "Vídeo"
    case audio = "Áudio"
    case sidecar = "Sidecar"
    case other = "Outro"

    var folderName: String {
        switch self {
        case .photo, .rawPhoto: "Fotos"
        case .video: "Vídeos"
        case .audio: "Áudios"
        case .sidecar: "Sidecars"
        case .other: "Outros"
        }
    }
}

enum DateSource: String, Codable, Sendable {
    case embeddedOriginal
    case embeddedDigitized
    case embeddedContainer
    case sidecar
    case filenameHighConfidence
    case filesystemOptional
    case unknown
}

enum Confidence: String, Codable, Sendable {
    case high, medium, low, unknown
}

struct CaptureMoment: Hashable, Codable, Sendable {
    let components: DateComponents
    let source: DateSource
    let confidence: Confidence

    var year: Int? { components.year }
    var month: Int? { components.month }
    var day: Int? { components.day }
}

enum ScanDisposition: String, Codable, Sendable {
    case exportable
    case ignoredSystemFile
    case ignoredSymbolicLink
    case ignoredPackage
    case inaccessible
}

struct MediaRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let sourceRootID: UUID
    let sourceURL: URL
    let relativePath: String
    let filename: String
    let fileSize: Int64
    let modificationDate: Date?
    let kind: MediaKind
    let captureMoment: CaptureMoment?
    let disposition: ScanDisposition
    let note: String?
    var sha256: String?

    init(
        sourceRootID: UUID,
        sourceURL: URL,
        relativePath: String,
        filename: String,
        fileSize: Int64,
        modificationDate: Date?,
        kind: MediaKind,
        captureMoment: CaptureMoment?,
        disposition: ScanDisposition = .exportable,
        note: String? = nil,
        sha256: String? = nil
    ) {
        id = UUID()
        self.sourceRootID = sourceRootID
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.filename = filename
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.kind = kind
        self.captureMoment = captureMoment
        self.disposition = disposition
        self.note = note
        self.sha256 = sha256
    }
}

struct MediaDuplicateGroup: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let hash: String
    let canonicalID: UUID
    let duplicateIDs: [UUID]

    init(hash: String, canonicalID: UUID, duplicateIDs: [UUID]) {
        id = UUID()
        self.hash = hash
        self.canonicalID = canonicalID
        self.duplicateIDs = duplicateIDs
    }
}

struct ScanSummary: Sendable {
    let records: [MediaRecord]
    let duplicateGroups: [MediaDuplicateGroup]

    var exportableRecords: [MediaRecord] { records.filter { $0.disposition == .exportable } }
    var totalBytes: Int64 { exportableRecords.reduce(0) { $0 + $1.fileSize } }
    var undatedCount: Int { exportableRecords.filter { $0.captureMoment == nil }.count }
    var enumerationErrorCount: Int { records.filter { $0.disposition == .inaccessible }.count }
    var isComplete: Bool { enumerationErrorCount == 0 }
}
