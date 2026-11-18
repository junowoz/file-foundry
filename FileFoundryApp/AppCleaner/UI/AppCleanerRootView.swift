import AppKit
import SwiftUI

/// App Cleaner rack: uninstall apps with everything they installed, find leftovers, clear developer caches,
/// check for updates and put removed items back. Everything goes to the Trash.
struct AppCleanerRootView: View {
    @StateObject private var model = AppCleanerModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            if model.needsFullDiskAccess && (model.mode == .apps || model.mode == .leftovers) { fullDiskBanner }
            if !model.problems.isEmpty { problemsBanner }
            content
        }
        .overlay(alignment: .bottom) { toastLayer }
        .navigationTitle("App Cleaner")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Look again for apps, leftovers and caches")
                    .disabled(model.mode == .updates || model.mode == .removed)
            }
        }
        .sheet(item: $model.pending) { pending in
            CleanerConfirmSheet(model: model, pending: pending)
        }
        .task { await model.start() }
        .task(id: model.mode) { model.ensureLoaded(for: model.mode) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in model.refreshRunning() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in model.refreshRunning() }
    }

    private var modeBar: some View {
        Picker("Mode", selection: $model.mode) {
            ForEach(CleanerMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: RackLayout.readableWidth)
        .padding(.horizontal, RackLayout.l)
        .padding(.vertical, RackLayout.s)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .apps: CleanerAppsView(model: model)
        case .leftovers: CleanerLeftoversView(model: model)
        case .caches: CleanerCachesView(model: model)
        case .updates: AppUpdatesView()
        case .removed: CleanerRemovedView(model: model)
        }
    }

    private var fullDiskBanner: some View {
        HStack(spacing: RackLayout.m) {
            Image(systemName: "lock.shield").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Allow Full Disk Access to find every file").lineLimit(1)
            Spacer(minLength: RackLayout.s)
            Button("Open Settings") { model.openFullDiskAccess() }
        }
        .padding(.horizontal, RackLayout.l).padding(.vertical, RackLayout.s)
        .background(.quaternary)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var problemsBanner: some View {
        HStack(alignment: .top, spacing: RackLayout.m) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: RackLayout.xs) {
                Text(model.problems.count == 1 ? "1 item was not moved" : "\(model.problems.count) items were not moved").font(.callout.weight(.medium))
                ForEach(Array(model.problems.prefix(3).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if model.problems.count > 3 { Text("and \(model.problems.count - 3) more").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: RackLayout.s)
            Button("Dismiss") { model.problems = [] }
        }
        .padding(.horizontal, RackLayout.l).padding(.vertical, RackLayout.s)
        .background(.quaternary)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var toastLayer: some View {
        ZStack {
            if let notice = model.notice {
                CleanerToast(notice: notice) {
                    if let record = notice.record { Task { await model.putBack(record) } }
                }
                .padding(.bottom, RackLayout.xxl + RackLayout.s)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                .id(notice.id)
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { model.dismissNotice(notice.id) }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice?.id)
    }
}

struct CleanerToast: View {
    let notice: CleanerNotice
    var putBack: () -> Void

    var body: some View {
        HStack(spacing: RackLayout.s) {
            Text(notice.text).lineLimit(1)
            if notice.record != nil {
                Text("·").foregroundStyle(.secondary)
                Button("Put Back", action: putBack).buttonStyle(.link)
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, RackLayout.m).padding(.vertical, RackLayout.s)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct CleanerTag: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, RackLayout.s - 2).padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}

/// Confirmation before anything is moved: totals, the items worth a second look, and refusals.
struct CleanerConfirmSheet: View {
    @ObservedObject var model: AppCleanerModel
    let pending: CleanerPending

    var body: some View {
        VStack(alignment: .leading, spacing: RackLayout.l) {
            Text(pending.title).font(.title3.weight(.semibold))
            Text("\(pending.count) \(pending.count == 1 ? "item" : "items") · \(CleanerFormat.bytes(pending.total))")
                .font(.headline).monospacedDigit()
            if let app = pending.runningApp {
                Label("Quit \(app) first, then try again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if !pending.notable.isEmpty {
                VStack(alignment: .leading, spacing: RackLayout.s) {
                    RackSectionHeader(title: "Worth a second look")
                    ScrollView {
                        VStack(alignment: .leading, spacing: RackLayout.xs) {
                            ForEach(Array(pending.notable.enumerated()), id: \.offset) { _, row in
                                Text("\(row.name) — \(CleanerFormat.bytes(row.size))\(row.isUserData ? " of app data" : "")")
                                    .font(.callout).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                    .foregroundStyle(.primary)
                }
            }
            if !pending.refused.isEmpty {
                VStack(alignment: .leading, spacing: RackLayout.xs) {
                    RackSectionHeader(title: "Skipped")
                    ForEach(Array(pending.refused.enumerated()), id: \.offset) { _, row in
                        Text("\(row.name): \(row.message)").font(.callout).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
            Text("Everything goes to the Trash. You can put it back from Removed.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: RackLayout.m) {
                Spacer()
                Button("Cancel") { model.pending = nil }.keyboardShortcut(.cancelAction)
                Button(pending.button) { Task { await model.confirmRemoval() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pending.count == 0 || pending.runningApp != nil || model.removing)
            }
        }
        .padding(RackLayout.xl)
        .frame(width: 460)
        .overlay { if model.removing { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(RackLayout.l) } }
    }
}
