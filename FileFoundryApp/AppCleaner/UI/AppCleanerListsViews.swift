import AppKit
import SwiftUI

struct CleanerLeftoversView: View {
    @ObservedObject var model: AppCleanerModel

    var body: some View {
        VStack(spacing: 0) {
            Text("These look left behind by apps that are no longer installed. Check each one before removing.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RackLayout.l).padding(.vertical, RackLayout.s)
            Divider()
            if model.orphansLoading && model.orphans.isEmpty {
                VStack(spacing: RackLayout.m) { ProgressView(); Text("Looking for leftovers…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.orphans.isEmpty {
                RackEmptyState(symbol: "checkmark.circle", title: "No Leftovers", message: "Nothing looks left behind by removed apps.")
            } else {
                CleanerItemList(model: model, scope: .orphans, items: model.orphans)
            }
            statusBar
        }
    }

    private var statusBar: some View {
        let chosen = model.checkedOrphans
        let size = chosen.reduce(Int64(0)) { $0 + $1.allocatedSize }
        return RackStatusBar(status: model.orphansLoading ? "Looking for leftovers…"
                             : "\(chosen.count) \(chosen.count == 1 ? "item" : "items") selected · \(CleanerFormat.bytes(size))") {
            Button("Move to Trash") { model.prepareOrphanRemoval() }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(chosen.isEmpty)
                .help("Moves the selected items to the Trash. You can put them back from Removed.")
        }
    }
}

struct CleanerCachesView: View {
    @ObservedObject var model: AppCleanerModel

    var body: some View {
        VStack(spacing: 0) {
            if model.cachesLoading && model.caches.isEmpty {
                VStack(spacing: RackLayout.m) { ProgressView(); Text("Looking for caches…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.caches.isEmpty {
                RackEmptyState(symbol: "hammer", title: "No Developer Caches", message: "No caches from developer tools were found.",
                               primaryTitle: "Rescan", primarySymbol: "arrow.clockwise", primaryAction: { model.loadCaches() })
            } else {
                List {
                    let groups = Dictionary(grouping: model.caches, by: \.tool)
                    ForEach(groups.keys.sorted(), id: \.self) { tool in
                        Section(tool) {
                            ForEach(groups[tool] ?? []) { cache in
                                CleanerCacheRow(cache: cache, home: model.home,
                                                checked: Binding(get: { model.cacheChecked.contains(cache.id) },
                                                                 set: { model.setCacheChecked(cache.id, on: $0) }),
                                                clear: { model.prepareCacheClear([cache]) },
                                                reveal: { model.reveal(cache.url) })
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            statusBar
        }
    }

    private var statusBar: some View {
        let chosen = model.checkedCaches
        let total = model.caches.reduce(Int64(0)) { $0 + $1.allocatedSize }
        let text = chosen.isEmpty
            ? (model.cachesLoading ? "Looking for caches…" : "\(model.caches.count) \(model.caches.count == 1 ? "cache" : "caches") · \(CleanerFormat.bytes(total))")
            : "\(chosen.count) selected · \(CleanerFormat.bytes(chosen.reduce(Int64(0)) { $0 + $1.allocatedSize }))"
        return RackStatusBar(status: text) {
            Button { model.loadCaches() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderless).controlSize(.small).disabled(model.cachesLoading)
            Button("Clear Selected") { model.prepareCacheClear(chosen) }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(chosen.isEmpty)
                .help("Moves the contents of the selected caches to the Trash")
        }
    }
}

struct CleanerCacheRow: View {
    let cache: DevCache
    let home: String
    let checked: Binding<Bool>
    let clear: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: RackLayout.m) {
            Toggle(isOn: checked) { EmptyView() }.toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: RackLayout.xs) {
                Text(cache.description).lineLimit(2)
                Text(CleanerFormat.shortPath(cache.url, home: home))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !cache.isPureCache { CleanerTag(text: "Some files may not be rebuilt", color: .orange) }
            }
            Spacer(minLength: RackLayout.s)
            Text(CleanerFormat.bytes(cache.allocatedSize)).foregroundStyle(.secondary).monospacedDigit()
            Button("Clear", action: clear).controlSize(.small)
                .help("Moves the contents to the Trash. The folder stays.")
        }
        .padding(.vertical, RackLayout.xs)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: reveal)
        .contextMenu { Button("Reveal in Finder", action: reveal) }
    }
}

struct CleanerRemovedView: View {
    @ObservedObject var model: AppCleanerModel

    var body: some View {
        VStack(spacing: 0) {
            if let summary = model.putBackSummary { summaryCard(summary) }
            if model.history.isEmpty {
                RackEmptyState(symbol: "arrow.uturn.backward.circle", title: "Nothing Removed Yet",
                               message: "Items you remove show up here, so you can put them back.")
            } else {
                List {
                    ForEach(model.history) { record in
                        row(record)
                    }
                }
                .listStyle(.inset)
            }
            RackStatusBar(status: model.history.isEmpty ? "No removals" : "\(model.history.count) \(model.history.count == 1 ? "removal" : "removals")")
        }
    }

    private func row(_ record: TrashRecord) -> some View {
        let emptied = model.emptiedCounts[record.id] ?? 0
        let allGone = emptied >= record.items.count
        return HStack(alignment: .top, spacing: RackLayout.m) {
            VStack(alignment: .leading, spacing: RackLayout.xs) {
                Text(record.label).lineLimit(1)
                Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(record.items.count) \(record.items.count == 1 ? "item" : "items") · \(CleanerFormat.bytes(record.totalSize))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if emptied > 0 {
                    Text(allGone ? "Emptied from the Trash. This can't be put back."
                         : "\(emptied) of \(record.items.count) items were emptied from the Trash.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: RackLayout.s)
            Button("Put Back") { Task { await model.putBack(record) } }
                .controlSize(.small).disabled(allGone)
        }
        .padding(.vertical, RackLayout.xs)
        .contextMenu {
            Button("Put Back") { Task { await model.putBack(record) } }.disabled(allGone)
            Button("Forget This Record") { Task { await model.forget(record) } }
        }
    }

    private func summaryCard(_ summary: CleanerPutBackSummary) -> some View {
        VStack(alignment: .leading, spacing: RackLayout.s) {
            HStack {
                Label("\(summary.label): put back \(summary.restored) \(summary.restored == 1 ? "item" : "items")",
                      systemImage: summary.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.failures.isEmpty ? Color.green : Color.orange)
                Spacer()
                Button("Dismiss") { model.putBackSummary = nil }.controlSize(.small)
            }
            ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, failure in
                Text("\((failure.originalPath as NSString).lastPathComponent): \(failure.reason)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .foundryCard()
        .padding(RackLayout.l)
    }
}
