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

    static let shared = AppUpdatesViewModel()

    private let checker: ThirdPartyUpdateChecker
    private var refreshQueued = false
    private var upgradeTask: Task<Void, Never>?

    init(checker: ThirdPartyUpdateChecker = ThirdPartyUpdateChecker()) {
        self.checker = checker
    }

    var isUpgrading: Bool { upgradingID != nil }

    var selectedEntry: AppUpdateEntry? {
        scan?.entries.first { $0.id == selectedID }
    }

    func refresh() async {
        guard !isChecking else { refreshQueued = true; return }
        isChecking = true
        let result = await checker.check()
        isChecking = false
        if !Task.isCancelled {
            scan = result
            if selectedEntry == nil { selectedID = result.entries.first?.id }
        }
        if refreshQueued, !Task.isCancelled {
            refreshQueued = false
            await refresh()
        }
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
        // One serial stream keeps the log chunks in the order brew wrote them.
        let (chunks, sink) = AsyncStream<String>.makeStream()
        let reader = Task { [weak self] in
            for await chunk in chunks { self?.appendLog(chunk) }
        }
        upgradeTask = Task { [weak self] in
            defer { sink.finish() }
            do {
                try await AppUpdateActions.upgradeCask(token: token) { chunk in sink.yield(chunk) }
                sink.finish()
                await reader.value
                self?.finishUpgrade(failure: nil)
            } catch is CancellationError {
                sink.finish(); await reader.value
                self?.finishUpgrade(failure: "Update cancelled.")
            } catch {
                sink.finish(); await reader.value
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
