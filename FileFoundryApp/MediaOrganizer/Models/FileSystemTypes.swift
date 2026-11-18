import Foundation

struct ReadOnlySourceURL: Hashable, Sendable, Codable {
    let url: URL

    init(_ url: URL) throws {
        guard url.isFileURL else { throw FileSystemPolicyError.notFileURL }
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

struct SourceRoot: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let location: ReadOnlySourceURL
    let displayName: String
    let bookmark: Data?

    init(url: URL, bookmark: Data? = nil) throws {
        id = UUID()
        location = try ReadOnlySourceURL(url)
        displayName = url.lastPathComponent
        self.bookmark = bookmark
    }
}

struct WritableDestinationURL: Hashable, Sendable, Codable {
    let url: URL

    init(validatedURL: URL) {
        url = validatedURL
    }
}

struct DestinationRoot: Hashable, Sendable, Codable {
    let url: URL
    let bookmark: Data?

    init(url: URL, bookmark: Data? = nil) throws {
        guard url.isFileURL else { throw FileSystemPolicyError.notFileURL }
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.bookmark = bookmark
    }
}

struct DestinationScope: Sendable {
    let root: DestinationRoot

    func writableURL(relativePath: String, policy: FileSystemPolicy) throws -> WritableDestinationURL {
        try policy.validatedDestination(relativePath: relativePath, in: root)
    }
}

enum FileSystemPolicyError: LocalizedError, Equatable {
    case notFileURL
    case sourceDestinationOverlap
    case sourceOutsideAllowedRoots
    case destinationOutsideScope
    case pathTraversal
    case symbolicLink
    case notRegularFile
    case outputAlreadyExists

    var errorDescription: String? {
        switch self {
        case .notFileURL: "The selected location isn't a valid local folder."
        case .sourceDestinationOverlap: "The destination folder must be fully separate from the sources."
        case .sourceOutsideAllowedRoots: "This file isn't inside an allowed source."
        case .destinationOutsideScope: "The operation tried to leave the allowed destination folder."
        case .pathTraversal: "The path contains unsafe components."
        case .symbolicLink: "Symbolic links aren't followed, for safety."
        case .notRegularFile: "This item isn't a regular file."
        case .outputAlreadyExists: "The destination already exists and won't be overwritten."
        }
    }
}
