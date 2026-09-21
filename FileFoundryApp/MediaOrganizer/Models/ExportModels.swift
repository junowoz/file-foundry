import Foundation

enum PlannedStatus: String, Codable, Sendable {
    case copy
    case exactDuplicate
    case undated
    case renamedCollision
    case sidecar
    case other
}

struct PlannedItem: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let record: MediaRecord
    let destinationRelativePath: String
    let status: PlannedStatus
    let duplicateGroupID: UUID?

    init(record: MediaRecord, destinationRelativePath: String, status: PlannedStatus, duplicateGroupID: UUID? = nil) {
        id = UUID()
        self.record = record
        self.destinationRelativePath = destinationRelativePath
        self.status = status
        self.duplicateGroupID = duplicateGroupID
    }
}

struct ExportPlan: Codable, Sendable {
    let operationID: UUID
    let template: String
    let items: [PlannedItem]

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.record.fileSize } }
}

enum CopyStatus: String, Codable, Sendable {
    case committedVerified
    case failed
    case cancelled
}

struct CopyRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let sourceRelativePath: String
    let destinationRelativePath: String
    let sha256: String?
    let bytes: Int64
    let status: CopyStatus
    let error: String?
}

struct ExportManifest: Codable, Sendable {
    let operationID: UUID
    let createdAt: Date
    let template: String
    let sources: [String]
    let outputRoot: String
    var records: [CopyRecord]
}
