import Foundation

public struct AppSettings: Codable, Equatable, Hashable, Sendable {
    public var compareMode: CompareMode
    public var includePackages: Bool
    public var preferredFolderPaths: [String]
    public var primaryFolderPaths: Set<String>

    public init(
        compareMode: CompareMode = .safe,
        includePackages: Bool = false,
        preferredFolderPaths: [String] = [],
        primaryFolderPaths: Set<String> = []
    ) {
        self.compareMode = compareMode
        self.includePackages = includePackages
        self.preferredFolderPaths = preferredFolderPaths
        self.primaryFolderPaths = primaryFolderPaths
    }

    private enum CodingKeys: String, CodingKey {
        case compareMode
        case includePackages
        case preferredFolderPaths
        case primaryFolderPaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.compareMode = try container.decodeIfPresent(CompareMode.self, forKey: .compareMode) ?? .safe
        self.includePackages = try container.decodeIfPresent(Bool.self, forKey: .includePackages) ?? false
        self.preferredFolderPaths = try container.decodeIfPresent([String].self, forKey: .preferredFolderPaths) ?? []
        self.primaryFolderPaths = try container.decodeIfPresent(Set<String>.self, forKey: .primaryFolderPaths) ?? []
    }
}
