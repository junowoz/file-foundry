import AppKit
import SwiftUI

/// App Updates: Homebrew casks, built-in updater apps and App Store apps in one list.
/// Embed it in a rack or window; it checks on appear and keeps its own state.
struct AppUpdatesView: View {
    @StateObject private var model: AppUpdatesViewModel

    init() {
        _model = StateObject(wrappedValue: AppUpdatesViewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            if let scan = model.scan, scan.pendingCount == 0 {
                upToDate(scan)
            } else if let scan = model.scan {
                HSplitView {
                    sidebar(scan)
                        .frame(minWidth: RackLayout.paneMin, idealWidth: RackLayout.paneIdeal, maxWidth: RackLayout.paneMax)
                    detail
                        .frame(minWidth: RackLayout.contentMin, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                RackEmptyState(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Checking Apps",
                    message: "Looking in Homebrew and in apps with a built-in updater.")
            }
            RackStatusBar(status: statusText, symbol: nil) {
                HStack(spacing: RackLayout.m) {
                    if let scan = model.scan, scan.pendingCount > 0 {
                        Text(scan.pendingCount == 1 ? "1 update" : "\(scan.pendingCount) updates")
                    }
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isChecking)
                }
            }
        }
        .task { await model.refresh() }
    }

    // MARK: - States

    private func upToDate(_ scan: AppUpdateScan) -> some View {
        let appStoreCount = scan.entries.filter(\.isAppStore).count
        return RackEmptyState(
            symbol: "checkmark.circle",
            title: "All Apps Are Up to Date",
            message: "Homebrew and the built-in updaters found nothing newer.",
            primaryTitle: "Check Again",
            primarySymbol: "arrow.clockwise",
            primaryAction: { Task { await model.refresh() } },
            footnote: appStoreCount > 0 ? "\(appStoreCount) App Store apps update through the App Store." : nil)
    }

    private var statusText: String {
        if model.isChecking { return "Checking for updates…" }
        guard let scan = model.scan else { return "Not checked yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        var text = "Checked " + formatter.localizedString(for: scan.checkedAt, relativeTo: Date())
        if !scan.warnings.isEmpty {
            text += " · \(scan.warnings.count) could not be checked"
        }
        return text
    }

    // MARK: - Sidebar

    private func sidebar(_ scan: AppUpdateScan) -> some View {
        List(selection: $model.selectedID) {
            ForEach(AppUpdateGroup.allCases, id: \.self) { group in
                let items = scan.entries.filter { $0.source.group == group }
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items) { entry in
                            row(entry).tag(entry.id)
                        }
                    }
                }
            }
            if scan.upToDateCount > 0 {
                Section {
                    HStack {
                        Text("Up to Date")
                        Spacer()
                        Text("\(scan.upToDateCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ entry: AppUpdateEntry) -> some View {
        HStack(spacing: RackLayout.s) {
            icon(for: entry).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: RackLayout.xs) {
                Text(entry.name).lineLimit(1)
                Text(versionSummary(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = model.selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: RackLayout.l) {
                    header(entry)
                    if let message = model.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    if model.logEntryID == entry.id, !model.log.isEmpty {
                        logView
                    }
                    if entry.releaseNotes != nil || entry.releaseNotesURL != nil {
                        releaseNotesSection(entry)
                    }
                }
                .padding(RackLayout.xl)
                .frame(maxWidth: RackLayout.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else {
            RackEmptyState(
                symbol: "app.badge.checkmark",
                title: "Select an App",
                message: "Choose an app to see its update.")
        }
    }

    private func header(_ entry: AppUpdateEntry) -> some View {
        HStack(alignment: .center, spacing: RackLayout.l) {
            icon(for: entry).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: RackLayout.xs) {
                Text(entry.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                Text(versionSummary(entry))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(sourceDescription(entry))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let date = entry.releaseDate {
                    Text("Released \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: RackLayout.s)
            primaryButton(entry)
        }
    }

    @ViewBuilder
    private func primaryButton(_ entry: AppUpdateEntry) -> some View {
        Group {
            switch entry.source {
            case .homebrew:
                Button { model.performPrimaryAction(for: entry) } label: {
                    Label("Update", systemImage: "arrow.down.circle")
                }
            case .sparkle:
                Button { model.performPrimaryAction(for: entry) } label: {
                    Label("Open App", systemImage: "arrow.up.forward.app")
                }
            case .appStore:
                Button { model.performPrimaryAction(for: entry) } label: {
                    Label("Open App Store", systemImage: "bag")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(model.isUpgrading)
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: RackLayout.s) {
            HStack(spacing: RackLayout.s) {
                if model.isUpgrading {
                    ProgressView().controlSize(.small)
                }
                Text(model.isUpgrading ? "Updating…" : "Update Log")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.isUpgrading {
                    Button("Cancel", role: .cancel) { model.cancelUpgrade() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            ScrollView {
                Text(model.log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: 180)
            .padding(RackLayout.m)
            .foundryCard()
        }
    }

    private func releaseNotesSection(_ entry: AppUpdateEntry) -> some View {
        VStack(alignment: .leading, spacing: RackLayout.s) {
            RackSectionHeader(title: "Release Notes")
            if let notes = entry.releaseNotes, !notes.isEmpty {
                Text(notes)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let url = entry.releaseNotesURL {
                Link("Open Release Notes", destination: url)
            }
        }
    }

    // MARK: - Helpers

    private func icon(for entry: AppUpdateEntry) -> some View {
        Group {
            if let url = entry.bundleURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func versionSummary(_ entry: AppUpdateEntry) -> String {
        if entry.isAppStore { return "Updated by the App Store" }
        if let installed = entry.installedVersion, let latest = entry.latestVersion {
            return "\(installed) → \(latest)"
        }
        if let latest = entry.latestVersion { return "Version \(latest)" }
        return entry.installedVersion.map { "Version \($0)" } ?? ""
    }

    private func sourceDescription(_ entry: AppUpdateEntry) -> String {
        switch entry.source {
        case .homebrew: "Installed with Homebrew"
        case .sparkle: "Has its own updater"
        case .appStore: "Installed from the App Store"
        }
    }
}
