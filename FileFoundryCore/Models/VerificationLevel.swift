public enum VerificationLevel: String, Codable, Hashable, CaseIterable, Sendable {
    case metadataMatch
    case sameSizeOnly
    case partialHashMatch
    case sha256Match
    case byteByByteConfirmed

    public var label: String {
        switch self {
        case .metadataMatch: "Matching details"
        case .sameSizeOnly: "Same size"
        case .partialHashMatch: "Partly checked"
        case .sha256Match: "Identical content"
        case .byteByByteConfirmed: "Identical content, fully checked"
        }
    }
}
