import Foundation

public struct AppSettings: Codable, Equatable, Hashable, Sendable {
    public var compareMode: CompareMode
    public var preferredFolderPaths: [String]
    public var primaryFolderPaths: Set<String>

    public init(
        compareMode: CompareMode = .safe,
        preferredFolderPaths: [String] = [],
        primaryFolderPaths: Set<String> = []
    ) {
        self.compareMode = compareMode
        self.preferredFolderPaths = preferredFolderPaths
        self.primaryFolderPaths = primaryFolderPaths
    }

    private enum CodingKeys: String, CodingKey {
        case compareMode
        case preferredFolderPaths
        case primaryFolderPaths
    }

    // Older saved settings may still contain "includePackages". It is ignored: packages are always skipped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.compareMode = try container.decodeIfPresent(CompareMode.self, forKey: .compareMode) ?? .safe
        self.preferredFolderPaths = try container.decodeIfPresent([String].self, forKey: .preferredFolderPaths) ?? []
        self.primaryFolderPaths = try container.decodeIfPresent(Set<String>.self, forKey: .primaryFolderPaths) ?? []
    }
}
