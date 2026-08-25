import Foundation

public struct DuplicateGroup: Identifiable, Codable, Equatable, Hashable, Sendable {
    public typealias ID = UUID

    public var id: ID
    public var files: [ScannedFile]
    public var sha256: String
    public var size: Int64
    public var totalLogicalWastedBytes: Int64
    public var totalAllocatedWastedBytes: Int64
    public var recommendedKeepFileID: ScannedFile.ID?
    public var recommendedRemovalFileIDs: Set<ScannedFile.ID>
    public var verificationLevel: VerificationLevel
    public var recommendationReasons: [ScannedFile.ID: [RecommendationReason]]
    public var containsSameUnderlyingFile: Bool

    public init(
        id: ID = UUID(),
        files: [ScannedFile],
        sha256: String,
        verificationLevel: VerificationLevel,
        recommendedKeepFileID: ScannedFile.ID? = nil,
        recommendedRemovalFileIDs: Set<ScannedFile.ID> = [],
        recommendationReasons: [ScannedFile.ID: [RecommendationReason]] = [:]
    ) {
        let size = files.first?.size ?? 0
        let allocatedSizes = files.compactMap(\.allocatedSize)
        let wastedCount = max(files.count - 1, 0)
        let resourceIDs = files.compactMap(\.fileResourceIdentifier)

        self.id = id
        self.files = files
        self.sha256 = sha256
        self.size = size
        let isExactMatch = verificationLevel != .metadataMatch
        self.totalLogicalWastedBytes = isExactMatch ? Int64(wastedCount) * size : 0
        self.totalAllocatedWastedBytes = isExactMatch && !allocatedSizes.isEmpty ? allocatedSizes.dropFirst().reduce(0, +) : 0
        self.recommendedKeepFileID = recommendedKeepFileID
        self.recommendedRemovalFileIDs = recommendedRemovalFileIDs
        self.verificationLevel = verificationLevel
        self.recommendationReasons = recommendationReasons
        self.containsSameUnderlyingFile = Set(resourceIDs).count < resourceIDs.count
    }

    public var removableCount: Int {
        recommendedRemovalFileIDs.count
    }

    public var allowsRemoval: Bool {
        verificationLevel != .metadataMatch
    }
}
