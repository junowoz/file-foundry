import Foundation

enum AppUpdateActionError: LocalizedError {
    case invalidToken(String)
    case homebrewNotFound
    case upgradeFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidToken(let token):
            "\"\(token)\" is not a valid Homebrew cask name."
        case .homebrewNotFound:
            "Homebrew is not installed. Install it to update these apps."
        case .upgradeFailed(let status):
            "The update did not finish (exit code \(status)). Check the log for details."
        }
    }
}

enum AppUpdateActions {
    /// Runs `brew upgrade --cask <token>` and streams its output. Cancelling the calling task stops brew.
    static func upgradeCask(token: String, onOutput: @escaping @Sendable (String) -> Void) async throws {
        guard HomebrewToken.isValid(token) else { throw AppUpdateActionError.invalidToken(token) }
        guard let path = ThirdPartyUpdateChecker.brewCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AppUpdateActionError.homebrewNotFound
        }
        let result = try await UpdateProcess.run(
            executable: URL(fileURLWithPath: path),
            arguments: ["upgrade", "--cask", token],
            timeout: 1800,
            onOutput: onOutput)
        guard result.status == 0 else { throw AppUpdateActionError.upgradeFailed(status: result.status) }
    }
}
