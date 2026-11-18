import Foundation

/// Where an app's update comes from, which decides how it is installed.
enum AppUpdateSource: Sendable, Hashable {
    case homebrew(token: String)
    case sparkle
    case appStore
}

/// Sections of the App Updates list, in display order.
enum AppUpdateGroup: Int, CaseIterable, Sendable {
    case homebrew
    case builtIn
    case appStore

    var title: String {
        switch self {
        case .homebrew: "Homebrew"
        case .builtIn: "Built-In Updater"
        case .appStore: "App Store"
        }
    }
}

extension AppUpdateSource {
    var group: AppUpdateGroup {
        switch self {
        case .homebrew: .homebrew
        case .sparkle: .builtIn
        case .appStore: .appStore
        }
    }
}

/// One app in the App Updates list.
struct AppUpdateEntry: Identifiable, Sendable, Equatable {
    /// Bundle path for apps found on disk, or `homebrew:<token>` for a cask without an app bundle.
    let id: String
    let name: String
    let bundleURL: URL?
    let installedVersion: String?
    let latestVersion: String?
    let source: AppUpdateSource
    /// Plain text, at most 2000 characters.
    let releaseNotes: String?
    let releaseNotesURL: URL?
    let releaseDate: Date?
    /// True for Homebrew and built-in updater apps with a newer version. App Store apps are listed but never pending.
    let hasUpdate: Bool

    var isAppStore: Bool {
        if case .appStore = source { return true }
        return false
    }
}

/// Result of one check. `entries` holds apps that need attention plus App Store apps.
struct AppUpdateScan: Sendable, Equatable {
    let entries: [AppUpdateEntry]
    /// Built-in updater apps that are current.
    let upToDateCount: Int
    let checkedAt: Date
    /// Non-fatal problems (a feed that could not be read, Homebrew timing out).
    let warnings: [String]

    var pendingCount: Int { entries.filter(\.hasUpdate).count }
}
