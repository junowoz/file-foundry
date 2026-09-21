import Foundation

struct FileSystemPolicy: Sendable {
    func validateDisjoint(sources: [SourceRoot], destination: DestinationRoot) throws {
        let destinationPath = canonicalPath(destination.url)
        for source in sources {
            let sourcePath = canonicalPath(source.location.url)
            if contains(destinationPath, sourcePath) || contains(sourcePath, destinationPath) {
                throw FileSystemPolicyError.sourceDestinationOverlap
            }
        }
    }

    func validateSourceFile(_ url: URL, roots: [SourceRoot]) throws -> ReadOnlySourceURL {
        let candidate = url.standardizedFileURL
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw FileSystemPolicyError.symbolicLink }
        guard values.isRegularFile == true else { throw FileSystemPolicyError.notRegularFile }
        let candidatePath = canonicalPath(candidate)
        guard roots.contains(where: { contains(canonicalPath($0.location.url), candidatePath) }) else {
            throw FileSystemPolicyError.sourceOutsideAllowedRoots
        }
        return try ReadOnlySourceURL(candidate)
    }

    func validatedDestination(relativePath: String, in root: DestinationRoot) throws -> WritableDestinationURL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw FileSystemPolicyError.pathTraversal
        }
        let candidate = components.reduce(root.url) { $0.appendingPathComponent($1, isDirectory: false) }.standardizedFileURL
        guard contains(canonicalPath(root.url), canonicalPathPreservingMissingTail(candidate)) else {
            throw FileSystemPolicyError.destinationOutsideScope
        }
        return WritableDestinationURL(validatedURL: candidate)
    }

    func validateOutputRootDoesNotExist(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw FileSystemPolicyError.outputAlreadyExists
        }
    }

    func validateDestinationAncestors(relativePath: String, in root: DestinationRoot) throws {
        _ = try validatedDestination(relativePath: relativePath, in: root)
        let components = relativePath.split(separator: "/").dropLast()
        var cursor = root.url
        for component in components {
            cursor.appendPathComponent(String(component), isDirectory: true)
            guard FileManager.default.fileExists(atPath: cursor.path) else { break }
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw FileSystemPolicyError.destinationOutsideScope
            }
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func canonicalPathPreservingMissingTail(_ url: URL) -> String {
        var cursor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: cursor.path), cursor.path != "/" {
            missing.insert(cursor.lastPathComponent, at: 0)
            cursor.deleteLastPathComponent()
        }
        return missing.reduce(cursor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL.path
    }

    private func contains(_ root: String, _ candidate: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
