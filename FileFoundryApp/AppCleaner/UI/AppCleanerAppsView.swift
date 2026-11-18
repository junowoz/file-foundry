import AppKit
import SwiftUI

@MainActor
enum CleanerIcons {
    private static let cache = NSCache<NSString, NSImage>()
    static func icon(for url: URL) -> NSImage {
        if let hit = cache.object(forKey: url.path as NSString) { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }
}

struct CleanerAppsView: View {
    @ObservedObject var model: AppCleanerModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                CleanerAppList(model: model)
                    .frame(minWidth: RackLayout.paneMin, idealWidth: RackLayout.paneIdeal, maxWidth: RackLayout.paneMax)
                detail.frame(minWidth: RackLayout.contentMin, maxWidth: .infinity, maxHeight: .infinity)
            }
            statusBar
        }
    }

    @ViewBuilder private var detail: some View {
        if let app = model.selectedApp {
            CleanerAppDetail(model: model, app: app).id(app.id)
        } else {
            CleanerDiskOverview(volumes: model.volumes)
        }
    }

    private var statusBar: some View {
        let count = model.checkedItems.count
        let size = model.checkedItems.reduce(Int64(0)) { $0 + $1.allocatedSize }
        return RackStatusBar(status: statusText(count: count, size: size)) {
            if model.selectedApp != nil {
                Button("Move to Trash") { model.prepareAppRemoval() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(count == 0 || model.selectedApp.map(model.isRunning) == true)
                    .help("Moves the selected items to the Trash. You can put them back from Removed.")
            }
        }
    }

    private func statusText(count: Int, size: Int64) -> String {
        if model.selectedApp != nil {
            if model.itemsLoading { return "Looking for files…" }
            return "\(count) \(count == 1 ? "item" : "items") selected · \(CleanerFormat.bytes(size))"
        }
        if model.appsLoading && model.apps.isEmpty { return "Reading your apps…" }
        return "\(model.apps.count) apps"
    }
}

struct CleanerAppList: View {
    @ObservedObject var model: AppCleanerModel

    var body: some View {
        let apps = model.filteredApps
        VStack(spacing: 0) {
            HStack(spacing: RackLayout.s) {
                HStack(spacing: RackLayout.xs) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search Apps", text: $model.search).textFieldStyle(.plain)
                }
                .padding(.horizontal, RackLayout.s).padding(.vertical, RackLayout.xs + 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: RackLayout.s))
                Menu {
                    Picker("Sort By", selection: $model.sortBySize) {
                        Text("Name").tag(false)
                        Text("Size").tag(true)
                    }.pickerStyle(.inline)
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Sort apps")
            }
            .padding(RackLayout.s)
            Divider()
            if apps.isEmpty {
                if model.appsLoading { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { Text(model.search.isEmpty ? "No apps found" : "No apps match").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                List(selection: Binding(get: { model.selectedAppID }, set: { model.selectApp($0) })) {
                    let mine = apps.filter { !$0.isApple }, apple = apps.filter(\.isApple)
                    if !mine.isEmpty {
                        Section("Your Apps") { ForEach(mine) { CleanerAppRow(model: model, app: $0).tag($0.id as String?) } }
                    }
                    if !apple.isEmpty {
                        Section("Apple Apps") { ForEach(apple) { CleanerAppRow(model: model, app: $0).tag($0.id as String?) } }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

struct CleanerAppRow: View {
    @ObservedObject var model: AppCleanerModel
    let app: InstalledApp

    var body: some View {
        HStack(spacing: RackLayout.s) {
            Image(nsImage: CleanerIcons.icon(for: app.url)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: RackLayout.xs / 2) {
                Text(app.name).lineLimit(1)
                if app.isWebApp || app.isAppStore || model.isRunning(app) {
                    HStack(spacing: RackLayout.xs) {
                        if app.isWebApp { CleanerTag(text: "Web App") }
                        if app.isAppStore { CleanerTag(text: "App Store") }
                        if model.isRunning(app) { CleanerTag(text: "Running", color: .green) }
                    }
                }
            }
            Spacer(minLength: RackLayout.xs)
            if let size = app.size { Text(CleanerFormat.bytes(size)).font(.callout).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.vertical, RackLayout.xs / 2)
        .contextMenu { Button("Reveal in Finder") { model.reveal(app.url) } }
    }
}

struct CleanerAppDetail: View {
    @ObservedObject var model: AppCleanerModel
    let app: InstalledApp

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isRunning(app) { runningBanner }
            if app.isApple {
                RackEmptyState(symbol: "apple.logo", title: "Part of macOS",
                               message: "Apple apps are part of the system, so App Cleaner can't remove them.")
            } else if model.itemsLoading {
                VStack(spacing: RackLayout.m) {
                    ProgressView()
                    Text("Looking for everything \(app.name) installed…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                RackEmptyState(symbol: "questionmark.folder", title: "Nothing Found", message: "No files were found for \(app.name).")
            } else {
                CleanerItemList(model: model, scope: .app, items: model.items)
            }
        }
    }

    private var header: some View {
        let total = model.items.reduce(Int64(0)) { $0 + $1.allocatedSize }
        return HStack(spacing: RackLayout.m) {
            Image(nsImage: CleanerIcons.icon(for: app.url)).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: RackLayout.xs) {
                Text(app.name).font(.title3.weight(.semibold)).lineLimit(1)
                Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: RackLayout.s)
            if !model.items.isEmpty {
                VStack(alignment: .trailing, spacing: RackLayout.xs / 2) {
                    Text(CleanerFormat.bytes(total)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text("in total").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(RackLayout.l)
    }

    private var runningBanner: some View {
        HStack(spacing: RackLayout.m) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text("Quit \(app.name) to remove it").lineLimit(1)
            Spacer(minLength: RackLayout.s)
            Button("Quit") { model.quit(app) }
        }
        .padding(.horizontal, RackLayout.l).padding(.vertical, RackLayout.s)
        .background(.quaternary)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Items grouped by kind with checkboxes; used for one app and for leftovers.
struct CleanerItemList: View {
    @ObservedObject var model: AppCleanerModel
    let scope: CleanerScope
    let items: [CleanupItem]

    var body: some View {
        List {
            ForEach(CleanerItemGroup.make(items)) { group in
                Section {
                    ForEach(group.items) { item in
                        CleanerItemRow(
                            item: item, home: model.home, refusal: model.refusal(scope, item.id),
                            checked: Binding(get: { model.isChecked(scope, item.id) },
                                             set: { model.setChecked(scope, ids: [item.id], on: $0) }),
                            reveal: { model.reveal(item.url) })
                    }
                } header: {
                    let ids = group.items.filter { model.refusal(scope, $0.id) == nil }.map(\.id)
                    let all = ids.allSatisfy { model.isChecked(scope, $0) }
                    HStack {
                        Text("\(group.kind.title) · \(CleanerFormat.bytes(group.total))")
                        Spacer()
                        Button(all ? "Select None" : "Select All") { model.setChecked(scope, ids: ids, on: !all) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

struct CleanerItemRow: View {
    let item: CleanupItem
    let home: String
    let refusal: String?
    let checked: Binding<Bool>
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: RackLayout.m) {
            Toggle(isOn: checked) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().disabled(refusal != nil)
            VStack(alignment: .leading, spacing: RackLayout.xs) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(CleanerFormat.shortPath(item.url, home: home))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if hasTags {
                    HStack(spacing: RackLayout.xs) {
                        switch item.confidence {
                        case .exact: EmptyView()
                        case .likely: CleanerTag(text: "Name match")
                        case .possible: CleanerTag(text: "Possible match")
                        }
                        if item.needsAdmin { CleanerTag(text: "Needs admin") }
                        if item.containsUserData { CleanerTag(text: "Contains app data", color: .orange) }
                        if let refusal { CleanerTag(text: refusal, color: .red) }
                    }
                }
            }
            Spacer(minLength: RackLayout.s)
            Text(CleanerFormat.bytes(item.allocatedSize)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, RackLayout.xs)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: reveal)
        .help(item.reason)
        .contextMenu { Button("Reveal in Finder", action: reveal) }
    }

    private var hasTags: Bool { item.confidence != .exact || item.needsAdmin || item.containsUserData || refusal != nil }
}

struct CleanerDiskOverview: View {
    let volumes: [VolumeInfo]

    var body: some View {
        VStack(spacing: RackLayout.xl) {
            VStack(spacing: RackLayout.m) {
                ForEach(volumes.prefix(3)) { volume in
                    VStack(alignment: .leading, spacing: RackLayout.s) {
                        HStack {
                            Label(volume.name, systemImage: volume.isExternal ? "externaldrive" : "internaldrive").font(.headline)
                            Spacer()
                            Text("\(CleanerFormat.bytes(volume.used)) of \(CleanerFormat.bytes(volume.total)) used")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        ProgressView(value: Double(volume.used), total: Double(max(volume.total, 1)))
                        HStack(spacing: RackLayout.l) {
                            Text("\(CleanerFormat.bytes(volume.available)) available")
                            if volume.purgeable > 0 { Text("\(CleanerFormat.bytes(volume.purgeable)) purgeable") }
                        }
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .foundryCard()
                }
            }
            .frame(maxWidth: 420)
            Text("Choose an app to see everything it installed")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(RackLayout.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
