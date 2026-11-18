import Foundation

struct HomebrewOutdatedCask: Sendable, Equatable {
    let token: String
    let name: String
    let installedVersion: String?
    let currentVersion: String?
}

enum HomebrewToken {
    /// Cask tokens as Homebrew writes them. A leading "-" is refused so a token can never read as an option.
    static func isValid(_ token: String) -> Bool {
        guard token.count <= 200 else { return false }
        return token.wholeMatch(of: #/[a-z0-9][a-z0-9@._+-]*/#) != nil
    }
}

enum HomebrewOutdatedParser {
    /// Parses `brew outdated --cask --greedy --json=v2`. Entries with an invalid token are skipped.
    static func parse(_ data: Data) throws -> [HomebrewOutdatedCask] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let casks = root["casks"] as? [[String: Any]] ?? []
        return casks.compactMap { entry in
            let token = (entry["token"] as? String) ?? (entry["name"] as? String)
            guard let token, HomebrewToken.isValid(token) else { return nil }
            return HomebrewOutdatedCask(
                token: token,
                name: displayName(entry["name"]) ?? token,
                installedVersion: firstVersion(entry["installed_versions"]),
                currentVersion: entry["current_version"] as? String)
        }
    }

    /// `name` is a list of display names in brew's JSON, but a plain string in some versions.
    private static func displayName(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        return (value as? [String])?.first
    }

    /// `installed_versions` is a list in brew's JSON, but a plain string in some versions.
    private static func firstVersion(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        return (value as? [String])?.first
    }
}
