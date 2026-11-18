import Foundation

/// Finds updates outside the App Store. Homebrew casks come from `brew outdated`, apps with an
/// https Sparkle feed are compared with their appcast, and App Store apps are listed only.
struct ThirdPartyUpdateChecker: Sendable {
    static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static let brewTimeout: TimeInterval = 60
    static let appcastLimit = 2_000_000

    var applicationDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)
    ]
    var session: URLSession = .shared

    func check() async -> AppUpdateScan {
        let apps = installedApps()
        var warnings: [String] = []

        let brew = await homebrewReport()
        warnings.append(contentsOf: brew.warnings)
        // Apps that Homebrew manages are not checked a second time through their own feed.
        let brewManaged = Set((brew.installedTokens + brew.outdated.map(\.token) + brew.outdated.map(\.name))
            .map(Self.normalized))

        var entries: [AppUpdateEntry] = []
        for cask in brew.outdated {
            let key = Self.normalized(cask.token)
            let app = apps.first { Self.normalized($0.name) == key || Self.normalized($0.name) == Self.normalized(cask.name) }
            entries.append(AppUpdateEntry(
                id: "homebrew:\(cask.token)",
                name: app?.name ?? cask.name,
                bundleURL: app?.bundleURL,
                installedVersion: cask.installedVersion,
                latestVersion: cask.currentVersion,
                source: .homebrew(token: cask.token),
                releaseNotes: nil,
                releaseNotesURL: nil,
                releaseDate: nil,
                hasUpdate: true))
        }

        let feedApps = apps.filter { app in
            guard !app.isAppStore, let feed = app.feedURL, feed.scheme == "https" else { return false }
            return !brewManaged.contains(Self.normalized(app.name))
        }
        var upToDate = 0
        await withTaskGroup(of: SparkleOutcome.self) { group in
            for app in feedApps {
                group.addTask { await self.checkSparkle(app) }
            }
            for await outcome in group {
                switch outcome {
                case .update(let entry): entries.append(entry)
                case .current: upToDate += 1
                case .failed(let name): warnings.append("Could not read the update feed for \(name).")
                }
            }
        }

        for app in apps where app.isAppStore {
            entries.append(AppUpdateEntry(
                id: app.bundleURL.path,
                name: app.name,
                bundleURL: app.bundleURL,
                installedVersion: app.displayVersion,
                latestVersion: nil,
                source: .appStore,
                releaseNotes: nil,
                releaseNotesURL: nil,
                releaseDate: nil,
                hasUpdate: false))
        }

        let sorted = entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return AppUpdateScan(entries: sorted, upToDateCount: upToDate, checkedAt: Date(), warnings: warnings)
    }

    /// Lowercase letters and digits only, so "Visual Studio Code" and "visual-studio-code" match.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    // MARK: - Homebrew

    struct HomebrewReport: Sendable {
        var outdated: [HomebrewOutdatedCask] = []
        var installedTokens: [String] = []
        var warnings: [String] = []
    }

    func homebrewReport() async -> HomebrewReport {
        var report = HomebrewReport()
        guard let path = Self.brewCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return report
        }
        let brew = URL(fileURLWithPath: path)
        do {
            let outdated = try await UpdateProcess.run(
                executable: brew,
                arguments: ["outdated", "--cask", "--greedy", "--json=v2"],
                timeout: Self.brewTimeout)
            report.outdated = try HomebrewOutdatedParser.parse(outdated.stdout)
        } catch {
            report.warnings.append("Homebrew could not be checked. \(error.localizedDescription)")
            return report
        }
        if let list = try? await UpdateProcess.run(executable: brew, arguments: ["list", "--cask"], timeout: Self.brewTimeout) {
            report.installedTokens = String(decoding: list.stdout, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter(HomebrewToken.isValid)
        }
        return report
    }

    // MARK: - Sparkle

    enum SparkleOutcome: Sendable {
        case update(AppUpdateEntry)
        case current
        case failed(String)
    }

    func checkSparkle(_ app: InstalledMacApp) async -> SparkleOutcome {
        guard let feed = app.feedURL, let data = await fetchAppcast(feed),
              let item = SparkleAppcastParser.newestItem(in: data) else {
            return .failed(app.name)
        }
        let latest: String
        let installed: String?
        if let short = item.shortVersion {
            latest = short
            installed = app.shortVersion ?? app.bundleVersion
        } else if let build = item.version {
            latest = build
            installed = app.bundleVersion ?? app.shortVersion
        } else {
            return .failed(app.name)
        }
        guard let installed else { return .failed(app.name) }
        guard AppVersionComparator.isNewer(latest, than: installed) else { return .current }
        return .update(AppUpdateEntry(
            id: app.bundleURL.path,
            name: app.name,
            bundleURL: app.bundleURL,
            installedVersion: installed,
            latestVersion: latest,
            source: .sparkle,
            releaseNotes: item.releaseNotes,
            releaseNotesURL: item.releaseNotesURL,
            releaseDate: item.pubDate,
            hasUpdate: true))
    }

    func fetchAppcast(_ url: URL) async -> Data? {
        let request = URLRequest(url: url, timeoutInterval: 15)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.appcastLimit { return nil }
            }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Installed apps

    func installedApps() -> [InstalledMacApp] {
        let fileManager = FileManager.default
        var apps: [InstalledMacApp] = []
        for directory in applicationDirectories {
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for url in contents where url.pathExtension == "app" {
                apps.append(readApp(at: url))
            }
        }
        return apps
    }

    private func readApp(at url: URL) -> InstalledMacApp {
        let info = (NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any]) ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let feed = (info["SUFeedURL"] as? String)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { URL(string: $0) }
        let receipt = url.appending(path: "Contents/_MASReceipt/receipt")
        return InstalledMacApp(
            name: name,
            bundleURL: url,
            shortVersion: info["CFBundleShortVersionString"] as? String,
            bundleVersion: info["CFBundleVersion"] as? String,
            feedURL: feed,
            isAppStore: FileManager.default.fileExists(atPath: receipt.path))
    }
}

struct InstalledMacApp: Sendable {
    let name: String
    let bundleURL: URL
    let shortVersion: String?
    let bundleVersion: String?
    let feedURL: URL?
    let isAppStore: Bool

    var displayVersion: String? { shortVersion ?? bundleVersion }
}
