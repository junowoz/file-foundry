import AppKit
import Foundation

@MainActor
final class AppUpdatesViewModel: ObservableObject {
    @Published private(set) var scan: AppUpdateScan?
    @Published private(set) var isChecking = false
    @Published var selectedID: String?
    @Published private(set) var upgradingID: String?
    /// The entry the current `log` belongs to.
    @Published private(set) var logEntryID: String?
    @Published private(set) var log = ""
    /// One-line note under the primary action (errors, "The app installs its own update.").
    @Published private(set) var message: String?

    private let checker: ThirdPartyUpdateChecker
    private var upgradeTask: Task<Void, Never>?

    init(checker: ThirdPartyUpdateChecker = ThirdPartyUpdateChecker()) {
        self.checker = checker
    }

    var isUpgrading: Bool { upgradingID != nil }

    var selectedEntry: AppUpdateEntry? {
        scan?.entries.first { $0.id == selectedID }
    }

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        let result = await checker.check()
        scan = result
        if selectedEntry == nil { selectedID = result.entries.first?.id }
        isChecking = false
    }

    func performPrimaryAction(for entry: AppUpdateEntry) {
        message = nil
        switch entry.source {
        case .homebrew(let token):
            startUpgrade(entry, token: token)
        case .sparkle:
            if let url = entry.bundleURL { NSWorkspace.shared.open(url) }
            message = "The app installs its own update."
        case .appStore:
            if let url = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(url) }
        }
    }

    func cancelUpgrade() {
        upgradeTask?.cancel()
    }

    private func startUpgrade(_ entry: AppUpdateEntry, token: String) {
        guard upgradeTask == nil else { return }
        upgradingID = entry.id
        logEntryID = entry.id
        log = "brew upgrade --cask \(token)\n"
        upgradeTask = Task { [weak self] in
            do {
                try await AppUpdateActions.upgradeCask(token: token) { chunk in
                    Task { @MainActor in self?.appendLog(chunk) }
                }
                self?.finishUpgrade(failure: nil)
            } catch is CancellationError {
                self?.finishUpgrade(failure: "Update cancelled.")
            } catch {
                self?.finishUpgrade(failure: error.localizedDescription)
            }
        }
    }

    private func finishUpgrade(failure: String?) {
        upgradingID = nil
        upgradeTask = nil
        message = failure
        appendLog(failure.map { "\n\($0)\n" } ?? "\nUpdate finished.\n")
        Task { await refresh() }
    }

    private func appendLog(_ text: String) {
        log += text
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }
}
