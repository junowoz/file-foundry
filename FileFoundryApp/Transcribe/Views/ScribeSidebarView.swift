import SwiftUI

enum ScribeLibraryFilter: String, CaseIterable, Identifiable {
    case all, completed, active, failed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Todas"
        case .completed: "Concluídas"
        case .active: "Em andamento"
        case .failed: "Com erro"
        }
    }
    var short: String {
        switch self {
        case .all: "Todas"
        case .completed: "Prontas"
        case .active: "Fila"
        case .failed: "Erros"
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
            Picker("Filtro", selection: $filterRaw) {
                ForEach(ScribeLibraryFilter.allCases) { f in
                    Text(f == .all ? f.title : "\(f.short) \(count(f))").tag(f.rawValue)
                }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.bottom, 8)
            List(selection: $selection) {
                ForEach(items) { meeting in
                    ScribeMeetingRow(meeting: meeting, canDelete: store.canDelete(meeting)) { requestDelete([meeting.id]) }
                        .tag(meeting.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if store.canDelete(meeting) {
                                Button(role: .destructive) { requestDelete([meeting.id]) } label: { Label("Excluir", systemImage: "trash") }
                            }
                        }
                        .contextMenu { menu(for: meeting) }
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .listStyle(.sidebar)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: items.map(\.id))
            .onDeleteCommand { requestDelete(selection) }
            .overlay { if items.isEmpty { emptyState } }
            recordingPanel
            footer
        }
        .searchable(text: $search, prompt: "Buscar transcrições")
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
            return "Excluir “\(m.title)”?"
        }
        return "Excluir \(ids.count) transcrições?"
    }

    private func requestDelete(_ ids: Set<UUID>) {
        let allowed = Set(store.meetings.filter { ids.contains($0.id) && store.canDelete($0) }.map(\.id))
        guard !allowed.isEmpty else {
            if !ids.isEmpty { store.showNotice("Itens em processamento não podem ser excluídos.") }
            return
        }
        ScribeDeleteConfirmation.present(title: dialogTitle(for: allowed)) { alsoOriginals in
            store.remove(ids: allowed, alsoTrashOriginals: alsoOriginals)
            selection.subtract(allowed)
        }
    }

    @ViewBuilder private func menu(for meeting: Meeting) -> some View {
        let targets = selection.contains(meeting.id) && selection.count > 1 ? selection : [meeting.id]
        Button("Mostrar no Finder") { store.reveal(meeting) }
        Divider()
        if targets.count > 1 {
            Button("Excluir \(targets.count) transcrições…", role: .destructive) { requestDelete(targets) }
        } else {
            Button("Excluir transcrição…", role: .destructive) { requestDelete(targets) }
                .disabled(!store.canDelete(meeting))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Biblioteca").font(.headline)
            Text("\(store.meetings.count)").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Menu {
                Button("Limpar concluídas (\(store.completedMeetings.count))…", role: .destructive) {
                    requestDelete(Set(store.completedMeetings.map(\.id)))
                }.disabled(store.completedMeetings.isEmpty)
                Button("Limpar com erro (\(store.failedMeetings.count))…", role: .destructive) {
                    requestDelete(Set(store.failedMeetings.map(\.id)))
                }.disabled(store.failedMeetings.isEmpty)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Mais ações da biblioteca").accessibilityLabel("Mais ações da biblioteca")
        }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            if !query.isEmpty {
                Text("Nenhum resultado para “\(query)”").foregroundStyle(.secondary)
                Button("Limpar busca") { search = "" }
            } else {
                switch filter {
                case .all: Text("Nenhuma transcrição ainda").foregroundStyle(.secondary)
                case .completed: Text("Nenhuma transcrição concluída").foregroundStyle(.secondary)
                case .active: Text("Nada em andamento").foregroundStyle(.secondary)
                case .failed: Text("Nenhuma com erro").foregroundStyle(.secondary)
                }
                if filter != .all { Button("Ver todas") { filterRaw = ScribeLibraryFilter.all.rawValue } }
            }
        }.multilineTextAlignment(.center).padding()
    }

    @ViewBuilder private var recordingPanel: some View {
        if store.isRecording {
            VStack(alignment: .leading, spacing: 12) {
                Label("Gravando \(ScribeFormatters.duration(store.recordingElapsed))", systemImage: "record.circle.fill")
                    .monospacedDigit().font(.headline)
                Button("Encerrar e transcrever") { store.stopRecording() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary)
        }
    }

    private var footer: some View {
        HStack {
            Button { openSettings() } label: { Label("Ajustes", systemImage: "gearshape") }
                .buttonStyle(.borderless).padding(.vertical, 10)
            Spacer()
        }.padding(.horizontal, 16)
    }
}

struct ScribeMeetingRow: View {
    let meeting: Meeting
    let canDelete: Bool
    let onDelete: () -> Void
    @State private var hovering = false

    private static let dateFormat = Date.FormatStyle().day().month(.abbreviated).locale(Locale(identifier: "pt_BR"))

    private var inFlight: Bool { TranscribeStore.isInFlight(meeting.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text(meeting.title).font(.body.weight(.medium)).lineLimit(2).help(meeting.title)
                Spacer(minLength: 0)
                if hovering && canDelete {
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Excluir transcrição").accessibilityLabel("Excluir transcrição")
                        .transition(.opacity)
                }
            }
            HStack(spacing: 5) {
                glyph
                Text(meta).lineLimit(1).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            if inFlight {
                ProgressView(value: min(max(meeting.progress, 0), 1)).progressViewStyle(.linear).controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
        .help(canDelete ? "" : "Em processamento: aguarde ou cancele para excluir")
    }

    private var meta: String {
        var parts = [meeting.status.rawValue]
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
        Text(text).font(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
