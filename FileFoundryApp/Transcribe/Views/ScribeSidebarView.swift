import SwiftUI

enum ScribeLibraryFilter: String, CaseIterable, Identifiable {
    case all, completed, active, failed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .completed: "Completed"
        case .active: "In Progress"
        case .failed: "Failed"
        }
    }
    var short: String {
        switch self {
        case .all: "All"
        case .completed: "Done"
        case .active: "Active"
        case .failed: "Failed"
        }
    }
    func matches(_ status: MeetingStatus) -> Bool {
        switch self {
        case .all: true
        case .completed: status == .completed
        case .active: TranscribeStore.isInFlight(status)
        case .failed: status == .failed
        }
    }
}

struct ScribeSidebarView: View {
    @ObservedObject var store: TranscribeStore
    var openSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("transcribe.library-filter") private var filterRaw = ScribeLibraryFilter.all.rawValue
    @State private var search = ""
    @State private var query = ""
    @State private var selection = Set<UUID>()

    private var filter: ScribeLibraryFilter { ScribeLibraryFilter(rawValue: filterRaw) ?? .all }

    private var filtered: [Meeting] {
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return store.meetings.filter { meeting in
            filter.matches(meeting.status)
                && (folded.isEmpty || store.searchableText(for: meeting).contains(folded))
        }
    }

    private func count(_ f: ScribeLibraryFilter) -> Int { store.meetings.filter { f.matches($0.status) }.count }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            header
            Picker("Filter", selection: $filterRaw) {
                ForEach(ScribeLibraryFilter.allCases) { f in
                    Text(f == .all ? f.title : "\(f.short) \(count(f))").tag(f.rawValue)
                }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, RackLayout.l).padding(.bottom, RackLayout.s)
            List(selection: $selection) {
                ForEach(items) { meeting in
                    ScribeMeetingRow(meeting: meeting, canDelete: store.canDelete(meeting)) { requestDelete([meeting.id]) }
                        .tag(meeting.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if store.canDelete(meeting) {
                                Button(role: .destructive) { requestDelete([meeting.id]) } label: { Label("Move to Trash", systemImage: "trash") }
                            }
                        }
                        .contextMenu { menu(for: meeting) }
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: items.map(\.id))
            .onDeleteCommand { requestDelete(selection) }
            .overlay { if items.isEmpty { emptyState } }
            recordingPanel
            footer
        }
        .searchable(text: $search, prompt: "Search transcripts")
        .navigationTitle("Transcribe")
        .task(id: search) {
            if search.isEmpty { query = ""; return }
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled { query = search }
        }
        .onChange(of: selection) { _, new in
            if new.count == 1, let id = new.first { store.selection = id }
        }
        .onChange(of: store.selection) { _, new in
            if let new, selection != [new], selection.count <= 1 { selection = [new] }
        }
        .onAppear { if let id = store.selection { selection = [id] } }
    }

    private func dialogTitle(for ids: Set<UUID>) -> String {
        if ids.count == 1, let id = ids.first, let m = store.meetings.first(where: { $0.id == id }) {
            return "Move “\(m.title)” to Trash?"
        }
        return "Move \(ids.count) transcripts to Trash?"
    }

    private func requestDelete(_ ids: Set<UUID>) {
        let allowed = Set(store.meetings.filter { ids.contains($0.id) && store.canDelete($0) }.map(\.id))
        guard !allowed.isEmpty else {
            if !ids.isEmpty { store.showNotice("Items in progress can't be moved to the Trash.") }
            return
        }
        ScribeDeleteConfirmation.present(title: dialogTitle(for: allowed)) { alsoOriginals in
            store.remove(ids: allowed, alsoTrashOriginals: alsoOriginals)
            selection.subtract(allowed)
        }
    }

    @ViewBuilder private func menu(for meeting: Meeting) -> some View {
        let targets = selection.contains(meeting.id) && selection.count > 1 ? selection : [meeting.id]
        Button("Show in Finder") { store.reveal(meeting) }
        Divider()
        if targets.count > 1 {
            Button("Move \(targets.count) Transcripts to Trash…", role: .destructive) { requestDelete(targets) }
        } else {
            Button("Move Transcript to Trash…", role: .destructive) { requestDelete(targets) }
                .disabled(!store.canDelete(meeting))
        }
    }

    private var header: some View {
        HStack(spacing: RackLayout.s) {
            Text("Library").font(.headline)
            Text("\(store.meetings.count)").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Menu {
                Button("Move Completed to Trash (\(store.completedMeetings.count))…", role: .destructive) {
                    requestDelete(Set(store.completedMeetings.map(\.id)))
                }.disabled(store.completedMeetings.isEmpty)
                Button("Move Failed to Trash (\(store.failedMeetings.count))…", role: .destructive) {
                    requestDelete(Set(store.failedMeetings.map(\.id)))
                }.disabled(store.failedMeetings.isEmpty)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More library actions").accessibilityLabel("More library actions")
        }.padding(.horizontal, RackLayout.l).padding(.top, RackLayout.m).padding(.bottom, RackLayout.s)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: RackLayout.s) {
            if !query.isEmpty {
                Text("No results for “\(query)”").foregroundStyle(.secondary)
                Button("Clear Search") { search = "" }
            } else {
                switch filter {
                case .all: Text("No transcripts yet").foregroundStyle(.secondary)
                case .completed: Text("No completed transcripts").foregroundStyle(.secondary)
                case .active: Text("Nothing in progress").foregroundStyle(.secondary)
                case .failed: Text("No failed transcripts").foregroundStyle(.secondary)
                }
                if filter != .all { Button("Show All") { filterRaw = ScribeLibraryFilter.all.rawValue } }
            }
        }.multilineTextAlignment(.center).padding()
    }

    @ViewBuilder private var recordingPanel: some View {
        if store.isRecording {
            VStack(alignment: .leading, spacing: RackLayout.m) {
                Label("Recording \(ScribeFormatters.duration(store.recordingElapsed))", systemImage: "record.circle.fill")
                    .monospacedDigit().font(.headline)
                Button("Stop and Transcribe") { store.stopRecording() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(RackLayout.l).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary)
        }
    }

    private var footer: some View {
        HStack {
            Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.borderless).padding(.vertical, RackLayout.s)
            Spacer()
        }.padding(.horizontal, RackLayout.l)
    }
}

struct ScribeMeetingRow: View {
    let meeting: Meeting
    let canDelete: Bool
    let onDelete: () -> Void
    @State private var hovering = false

    private static let dateFormat = Date.FormatStyle().day().month(.abbreviated)

    private var inFlight: Bool { TranscribeStore.isInFlight(meeting.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: RackLayout.s) {
            HStack(alignment: .top, spacing: RackLayout.s) {
                Text(meeting.title).font(.body.weight(.medium)).lineLimit(2).help(meeting.title)
                Spacer(minLength: 0)
                if hovering && canDelete {
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Move to Trash").accessibilityLabel("Move to Trash")
                        .transition(.opacity)
                }
            }
            HStack(spacing: RackLayout.xs) {
                glyph
                Text(meta).lineLimit(1).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            if inFlight {
                ProgressView(value: min(max(meeting.progress, 0), 1)).progressViewStyle(.linear).controlSize(.small)
            }
        }
        .padding(.vertical, RackLayout.s)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
        .help(canDelete ? "" : "In progress. Cancel first to move it to the Trash.")
    }

    private var meta: String {
        var parts = [meeting.status.displayName]
        if meeting.durationSeconds > 0 { parts.append(ScribeFormatters.duration(meeting.durationSeconds)) }
        parts.append(meeting.createdAt.formatted(Self.dateFormat))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var glyph: some View {
        switch meeting.status {
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default: Image(systemName: "waveform").foregroundStyle(Color.accentColor).symbolEffect(.variableColor.iterative, isActive: true)
        }
    }
}

struct ScribeToastView: View {
    let text: String
    var body: some View {
        Text(text).font(.callout.weight(.medium)).padding(.horizontal, RackLayout.m).padding(.vertical, RackLayout.s)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
