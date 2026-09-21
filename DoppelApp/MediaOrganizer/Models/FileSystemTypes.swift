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
        case .notFileURL: "A localização selecionada não é uma pasta local válida."
        case .sourceDestinationOverlap: "A pasta de destino precisa ser totalmente separada das origens."
        case .sourceOutsideAllowedRoots: "O arquivo não está dentro de uma origem autorizada."
        case .destinationOutsideScope: "A operação tentou sair da pasta de destino autorizada."
        case .pathTraversal: "O caminho contém componentes inseguros."
        case .symbolicLink: "Links simbólicos não são seguidos por segurança."
        case .notRegularFile: "O item não é um arquivo regular."
        case .outputAlreadyExists: "O destino já existe e não será sobrescrito."
        }
    }
}
