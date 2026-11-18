import AppKit
import SwiftUI

enum CleanerMode: String, CaseIterable, Identifiable {
    case apps, leftovers, caches, updates, removed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apps: "Apps"
        case .leftovers: "Leftovers"
        case .caches: "Developer Caches"
        case .updates: "Updates"
        case .removed: "Removed"
        }
    }
}

extension LeftoverKind {
    var title: String {
        switch self {
        case .appBundle: "App"
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .container: "Containers"
        case .groupContainer: "Group Containers"
        case .savedState: "Saved State"
        case .logs: "Logs"
        case .httpStorage: "HTTP Storage"
        case .webKit: "Web Data"
        case .cookies: "Cookies"
        case .launchAgent: "Launch Agents"
        case .launchDaemon: "Launch Daemons"
        case .privilegedHelper: "Helper Tools"
        case .applicationScripts: "Application Scripts"
        }
    }
}

enum CleanerFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func shortPath(_ url: URL, home: String) -> String {
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// "Containers/com.foo.app" for items inside ~/Library, the short path otherwise.
    static func libraryName(_ url: URL, home: String) -> String {
        let library = home + "/Library/"
        return url.path.hasPrefix(library) ? String(url.path.dropFirst(library.count)) : shortPath(url, home: home)
    }
}

struct CleanerItemGroup: Identifiable {
    let kind: LeftoverKind
    let items: [CleanupItem]
    var id: String { kind.rawValue }
    var total: Int64 { items.reduce(0) { $0 + $1.allocatedSize } }

    static func make(_ items: [CleanupItem]) -> [CleanerItemGroup] {
        let order = LeftoverKind.allCases
        let grouped = Dictionary(grouping: items, by: \.kind)
        return order.compactMap { kind in
            guard let list = grouped[kind], !list.isEmpty else { return nil }
            return CleanerItemGroup(kind: kind, items: list.sorted { $0.allocatedSize > $1.allocatedSize })
        }
    }
}

struct CleanerPending: Identifiable {
    struct Refusal { let name: String; let message: String }
    struct Notable { let name: String; let size: Int64; let isUserData: Bool }
    enum Source { case app(InstalledApp), orphans, caches }

    let id = UUID()
    let source: Source
    let label: String
    let title: String
    let button: String
    let items: [CleanupItem]
    let caches: [DevCache]
    let refused: [Refusal]
    let runningApp: String?
    let notable: [Notable]

    var count: Int { items.count + caches.count }
    var total: Int64 { items.reduce(0) { $0 + $1.allocatedSize } + caches.reduce(0) { $0 + $1.allocatedSize } }
}

struct CleanerNotice: Identifiable {
    let id = UUID()
    let text: String
    let record: TrashRecord?
}

struct CleanerPutBackSummary {
    let label: String
    let restored: Int
    let failures: [PutBackFailure]
}

enum CleanerScope { case app, orphans }

@MainActor
final class AppCleanerModel: ObservableObject {
    static let largeItem: Int64 = 500_000_000

    let env: CleanerEnvironment
    let trash: CleanerTrash
    let home: String

    @Published var mode: CleanerMode = .apps
    @Published private(set) var needsFullDiskAccess = false
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published var notice: CleanerNotice?
    @Published var problems: [String] = []
    @Published var pending: CleanerPending?
    @Published private(set) var removing = false

    // Apps
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var appsLoading = false
    @Published var search = ""
    @Published var sortBySize = false
    @Published private(set) var selectedAppID: String?
    @Published private(set) var runningIDs: Set<String> = []
    @Published private(set) var items: [CleanupItem] = []
    @Published private(set) var itemsLoading = false
    @Published private(set) var checked: Set<String> = []
    @Published private(set) var refusals: [String: String] = [:]

    // Leftovers
    @Published private(set) var orphans: [CleanupItem] = []
    @Published private(set) var orphansLoading = false
    @Published private(set) var orphansLoaded = false
    @Published private(set) var orphanChecked: Set<String> = []

    // Developer caches
    @Published private(set) var caches: [DevCache] = []
    @Published private(set) var cachesLoading = false
    @Published private(set) var cachesLoaded = false
    @Published private(set) var cacheChecked: Set<String> = []

    // Removed
    @Published private(set) var history: [TrashRecord] = []
    @Published private(set) var emptiedCounts: [UUID: Int] = [:]
    @Published var putBackSummary: CleanerPutBackSummary?

    private var appsTask: Task<Void, Never>?
    private var itemsTask: Task<Void, Never>?
    private var orphansTask: Task<Void, Never>?
    private var cachesTask: Task<Void, Never>?

    init(env: CleanerEnvironment = .live()) {
        self.env = env
        self.trash = CleanerTrash(env: env)
        self.home = env.homeURL.path
        self.runningIDs = env.runningBundleIDs()
    }

    // MARK: Derived

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }

    func isRunning(_ app: InstalledApp) -> Bool {
        guard let id = app.bundleID else { return false }
        return runningIDs.contains(id)
    }

    var filteredApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let list = query.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
        if sortBySize { return list.sorted { ($0.size ?? -1) > ($1.size ?? -1) } }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var checkedItems: [CleanupItem] { items.filter { checked.contains($0.id) } }
    var checkedOrphans: [CleanupItem] { orphans.filter { orphanChecked.contains($0.id) } }
    var checkedCaches: [DevCache] { caches.filter { cacheChecked.contains($0.id) } }

    func isChecked(_ scope: CleanerScope, _ id: String) -> Bool {
        scope == .app ? checked.contains(id) : orphanChecked.contains(id)
    }

    func setChecked(_ scope: CleanerScope, ids: [String], on: Bool) {
        switch scope {
        case .app: if on { checked.formUnion(ids) } else { checked.subtract(ids) }
        case .orphans: if on { orphanChecked.formUnion(ids) } else { orphanChecked.subtract(ids) }
        }
    }

    func setCacheChecked(_ id: String, on: Bool) {
        if on { cacheChecked.insert(id) } else { cacheChecked.remove(id) }
    }

    // MARK: Loading

    func start() async {
        loadApps()
        await reloadHistory()
        let env = self.env
        needsFullDiskAccess = await Self.lacksContainerAccess(env: env)
        volumes = await Self.loadVolumes()
    }

    func ensureLoaded(for mode: CleanerMode) {
        switch mode {
        case .leftovers where !orphansLoaded && !orphansLoading: loadOrphans()
        case .caches where !cachesLoaded && !cachesLoading: loadCaches()
        case .removed: Task { await reloadHistory() }
        default: break
        }
    }

    func rescan() {
        switch mode {
        case .apps: loadApps(); if let id = selectedAppID { selectApp(id, force: true) }
        case .leftovers: loadOrphans()
        case .caches: loadCaches()
        default: break
        }
        Task {
            volumes = await Self.loadVolumes()
            needsFullDiskAccess = await Self.lacksContainerAccess(env: env)
        }
    }

    func refreshRunning() { runningIDs = env.runningBundleIDs() }

    func loadApps() {
        appsTask?.cancel()
        appsLoading = true
        appsTask = Task {
            do {
                let list = try await AppInventory.list(env: env)
                if Task.isCancelled { return }
                let keepSizes = Dictionary(uniqueKeysWithValues: apps.compactMap { app in app.size.map { (app.id, $0) } })
                apps = list.map { var a = $0; a.size = keepSizes[a.id]; return a }
                appsLoading = false
                if let id = selectedAppID, !apps.contains(where: { $0.id == id }) { selectApp(nil) }
                var buffer: [String: Int64] = [:]
                // Sizes arrive one by one; publishing in batches avoids redrawing the list hundreds of times.
                for await entry in AppInventory.sizeStream(for: list) {
                    if Task.isCancelled { return }
                    buffer[entry.id] = entry.size
                    if buffer.count >= 12 { applySizes(buffer); buffer.removeAll() }
                }
                applySizes(buffer)
            } catch { appsLoading = false }
            appsLoading = false
        }
    }

    private func applySizes(_ sizes: [String: Int64]) {
        guard !sizes.isEmpty else { return }
        apps = apps.map { app in
            guard let size = sizes[app.id] else { return app }
            var copy = app; copy.size = size; return copy
        }
    }

    func selectApp(_ id: String?, force: Bool = false) {
        if id == selectedAppID && !force { return }
        itemsTask?.cancel()
        selectedAppID = id
        items = []; checked = []; refusals = [:]
        guard let app = selectedApp else { itemsLoading = false; return }
        itemsLoading = true
        let installed = apps
        itemsTask = Task {
            do {
                let found = try await LeftoverFinder(env: env).find(app: app, installedApps: installed)
                if Task.isCancelled { return }
                let blocked = await Self.refusals(for: found, env: env, owner: app)
                if Task.isCancelled { return }
                items = found
                refusals = blocked
                checked = Set(found.filter { $0.selectedByDefault && blocked[$0.id] == nil }.map(\.id))
            } catch {}
            if !Task.isCancelled { itemsLoading = false }
        }
    }

    func loadOrphans() {
        orphansTask?.cancel()
        orphansLoading = true
        let installed = apps
        orphansTask = Task {
            do {
                var list = installed
                if list.isEmpty { list = try await AppInventory.list(env: env) }
                let found = try await OrphanFinder(env: env).find(installedApps: list)
                if Task.isCancelled { return }
                let blocked = await Self.refusals(for: found, env: env, owner: nil)
                if Task.isCancelled { return }
                orphans = found
                orphanChecked = []
                refusals.merge(blocked) { $1 }
                orphansLoaded = true
            } catch {}
            if !Task.isCancelled { orphansLoading = false }
        }
    }

    func loadCaches() {
        cachesTask?.cancel()
        cachesLoading = true
        cachesTask = Task {
            do {
                let found = try await DevCacheCatalog.scan(env: env)
                if Task.isCancelled { return }
                caches = found
                cacheChecked = cacheChecked.intersection(found.map(\.id))
                cachesLoaded = true
            } catch {}
            if !Task.isCancelled { cachesLoading = false }
        }
    }

    func reloadHistory() async {
        let records = await trash.history()
        history = records
        emptiedCounts = await Self.emptiedCounts(records)
    }

    nonisolated static func refusals(for items: [CleanupItem], env: CleanerEnvironment, owner: InstalledApp?) async -> [String: String] {
        var out: [String: String] = [:]
        for item in items {
            if case .refused(let why) = CleanerSafety.check(item.url, env: env, owner: owner) { out[item.id] = why.message }
        }
        return out
    }

    nonisolated static func lacksContainerAccess(env: CleanerEnvironment) async -> Bool {
        let path = env.userLibrary.appending(path: "Containers", directoryHint: .isDirectory).path
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) == nil
    }

    nonisolated static func loadVolumes() async -> [VolumeInfo] { VolumeInfo.all() }

    nonisolated static func emptiedCounts(_ records: [TrashRecord]) async -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        for record in records {
            let gone = record.items.filter { item in
                guard let path = item.trashPath else { return true }
                return !FileManager.default.fileExists(atPath: path)
            }.count
            if gone > 0 { out[record.id] = gone }
        }
        return out
    }

    // MARK: Removal

    func prepareAppRemoval() {
        guard let app = selectedApp else { return }
        let chosen = checkedItems
        guard !chosen.isEmpty else { return }
        let title = chosen.count == 1 && chosen[0].kind == .appBundle ? "Move \(app.name) to the Trash?" : "Move \(chosen.count) Items to the Trash?"
        prepare(source: .app(app), label: "Uninstall \(app.name)", title: title, button: "Move to Trash", items: chosen, caches: [], owner: app)
    }

    func prepareOrphanRemoval() {
        let chosen = checkedOrphans
        guard !chosen.isEmpty else { return }
        prepare(source: .orphans, label: "Remove Leftovers", title: "Move \(chosen.count) Items to the Trash?", button: "Move to Trash", items: chosen, caches: [], owner: nil)
    }

    func prepareCacheClear(_ list: [DevCache]) {
        guard !list.isEmpty else { return }
        let title = list.count == 1 ? "Clear \(list[0].tool)?" : "Clear \(list.count) Caches?"
        let label = list.count == 1 ? "Clear \(list[0].tool) Cache" : "Clear Developer Caches"
        prepare(source: .caches, label: label, title: title, button: "Clear", items: [], caches: list, owner: nil)
    }

    private func prepare(source: CleanerPending.Source, label: String, title: String, button: String,
                         items: [CleanupItem], caches: [DevCache], owner: InstalledApp?) {
        var allowed: [CleanupItem] = [], refused: [CleanerPending.Refusal] = []
        var allowedCaches: [DevCache] = []
        var running: String?
        for item in items {
            switch CleanerSafety.check(item.url, env: env, owner: owner) {
            case .allowed: allowed.append(item)
            case .refused(let why): refused.append(.init(name: CleanerFormat.libraryName(item.url, home: home), message: why.message))
            case .appRunning: running = owner?.name ?? "the app"
            }
        }
        for cache in caches {
            switch CleanerSafety.check(cache.url, env: env, owner: nil) {
            case .allowed: allowedCaches.append(cache)
            case .refused(let why): refused.append(.init(name: cache.tool, message: why.message))
            case .appRunning: running = cache.tool
            }
        }
        if let owner, isRunning(owner) { running = owner.name }
        let notable = allowed
            .filter { $0.containsUserData || $0.allocatedSize >= Self.largeItem }
            .sorted { $0.allocatedSize > $1.allocatedSize }
            .map { CleanerPending.Notable(name: CleanerFormat.libraryName($0.url, home: home), size: $0.allocatedSize, isUserData: $0.containsUserData) }
        pending = CleanerPending(source: source, label: label, title: title, button: button, items: allowed, caches: allowedCaches,
                                 refused: refused, runningApp: running, notable: notable)
    }

    func confirmRemoval() async {
        guard let p = pending, !removing else { return }
        removing = true
        let report: RemovalReport
        if case .caches = p.source {
            var requests: [RemovalRequest] = []
            for cache in p.caches { requests += (try? await DevCacheCatalog.removalRequests(for: cache)) ?? [] }
            report = await trash.remove(requests, label: p.label)
        } else {
            report = await trash.remove(p.items, label: p.label)
        }
        pending = nil
        removing = false
        problems = report.failures.map { "\($0.url.lastPathComponent): \(Self.describe($0.status))" }
        let moved = Set(report.outcomes.filter(\.succeeded).map { $0.url.path })
        items.removeAll { moved.contains($0.id) }
        orphans.removeAll { moved.contains($0.id) }
        checked.subtract(moved); orphanChecked.subtract(moved)
        switch p.source {
        case .app(let app):
            if moved.contains(app.url.path) { apps.removeAll { $0.id == app.id }; selectApp(nil) } else { selectApp(app.id, force: true) }
            notify(report, text: Self.appText(app.name, moved: moved.count))
        case .orphans:
            notify(report, text: moved.count == 1 ? "Moved 1 item to the Trash" : "Moved \(moved.count) items to the Trash")
        case .caches:
            loadCaches()
            notify(report, text: "Cleared \(CleanerFormat.bytes(report.freedBytes)) from \(p.caches.count == 1 ? p.caches[0].tool : "\(p.caches.count) caches")")
        }
        await reloadHistory()
        volumes = await Self.loadVolumes()
    }

    private func notify(_ report: RemovalReport, text: String) {
        guard report.record != nil else { return }
        notice = CleanerNotice(text: text, record: report.record)
    }

    static func appText(_ name: String, moved: Int) -> String {
        moved <= 1 ? "Moved \(name) to the Trash" : "Moved \(name) and \(moved - 1) \(moved == 2 ? "item" : "items") to the Trash"
    }

    static func describe(_ status: RemovalStatus) -> String {
        switch status {
        case .trashed: "Moved to the Trash."
        case .blocked(.refused(let why)): why.message
        case .blocked(.appRunning): "Quit the app first."
        case .blocked(.allowed): "Not removed."
        case .failed(let message): message
        case .cancelled: "Cancelled."
        }
    }

    func putBack(_ record: TrashRecord) async {
        let report = await trash.putBack(record)
        putBackSummary = CleanerPutBackSummary(label: record.label, restored: report.restored.count, failures: report.failures)
        notice = CleanerNotice(text: report.restored.isEmpty ? "Nothing could be put back" : "Put back \(report.restored.count) \(report.restored.count == 1 ? "item" : "items")", record: nil)
        await reloadHistory()
        if !report.restored.isEmpty {
            loadApps()
            orphansLoaded = false; cachesLoaded = false
            if mode == .leftovers { loadOrphans() }
            if mode == .caches { loadCaches() }
            if let id = selectedAppID { selectApp(id, force: true) }
        }
    }

    func forget(_ record: TrashRecord) async {
        await trash.forget(record)
        await reloadHistory()
    }

    func dismissNotice(_ id: UUID) { if notice?.id == id { notice = nil } }

    func quit(_ app: InstalledApp) {
        guard let id = app.bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
        Task { try? await Task.sleep(for: .seconds(1)); refreshRunning() }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
}
