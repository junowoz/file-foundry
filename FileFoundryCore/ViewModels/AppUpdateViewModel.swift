import Foundation

public enum AppUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate(version: String)
    case updateAvailable(AppRelease)
    case downloading(AppRelease)
    case readyToInstall(StagedAppUpdate)
    case installing(AppRelease)
    case failed(String)
}

@MainActor
public final class AppUpdateViewModel: ObservableObject {
    @Published public private(set) var status: AppUpdateStatus = .idle

    /// UserDefaults key for the "check automatically" preference (default on).
    public static let autoCheckDefaultsKey = "autoCheckForUpdates"
    public static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    private let service: AppUpdateService
    private var stagedUpdate: StagedAppUpdate?
    private var lastCheckDate: Date?

    public init(service: AppUpdateService = AppUpdateService()) {
        self.service = service
    }

    public var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing:
            true
        case .idle, .upToDate, .updateAvailable, .readyToInstall, .failed:
            false
        }
    }

    /// The release the user can install now, if any. Drives the "Update Available" button.
    public var availableRelease: AppRelease? {
        switch status {
        case .updateAvailable(let release), .downloading(let release), .installing(let release):
            release
        case .readyToInstall(let staged):
            staged.release
        case .idle, .checking, .upToDate, .failed:
            nil
        }
    }

    public func checkForUpdates() async {
        service.cleanup(stagedUpdate)
        stagedUpdate = nil
        status = .checking
        lastCheckDate = Date()

        do {
            let release = try await service.latestRelease()
            if service.isUpdateAvailable(release) {
                status = .updateAvailable(release)
            } else {
                status = .upToDate(version: AppMetadata.version)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Background check: changes nothing unless a newer release exists, and never shows errors.
    /// Skips when a check ran in the last 24 hours or an update flow is already in progress.
    public func checkSilentlyIfDue(now: Date = Date()) async {
        guard !isBusy, availableRelease == nil else { return }
        if let lastCheckDate, now.timeIntervalSince(lastCheckDate) < Self.autoCheckInterval { return }
        lastCheckDate = now

        guard let release = try? await service.latestRelease(),
              service.isUpdateAvailable(release),
              !isBusy, availableRelease == nil
        else { return }
        status = .updateAvailable(release)
    }

    public func downloadAvailableUpdate() async -> StagedAppUpdate? {
        guard case .updateAvailable(let release) = status else { return nil }
        status = .downloading(release)

        do {
            let staged = try await service.downloadAndStage(release)
            stagedUpdate = staged
            status = .readyToInstall(staged)
            return staged
        } catch {
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    public func markInstalling(_ stagedUpdate: StagedAppUpdate) {
        status = .installing(stagedUpdate.release)
    }

    public func fail(_ error: Error) {
        status = .failed(error.localizedDescription)
    }

    public func cleanupStagedUpdate() {
        service.cleanup(stagedUpdate)
        stagedUpdate = nil
        if case .readyToInstall(let staged) = status {
            status = .updateAvailable(staged.release)
        }
    }
}

