import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ScribeMeetingDetailView: View {
    @ObservedObject var store: TranscribeStore
    let meeting: Meeting
    @State private var tab = 0
    @State private var showRename = false
    @State private var title = ""
    @State private var copied = false
    @State private var showPlayer = false
    @State private var player: AVPlayer?
    @State private var query = ""
    @State private var playbackError = false
    @AppStorage("transcribe.text-size") private var textSize = 16.0

    var body: some View {
        VStack(spacing: 0) {
            header
            if meeting.status == .failed, !meeting.text.isEmpty {
                HStack {
                    Label(meeting.errorMessage ?? "The text was kept. Try finishing again.", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Try Again") { store.retry(meeting) }.disabled(store.isBusy || store.isRecording)
                }.padding(RackLayout.l).background(.quaternary)
            }
            if !meeting.text.isEmpty || meeting.status == .completed {
                HStack(spacing: RackLayout.l) {
                    Picker("Content", selection: $tab) {
                        Text("Transcript").tag(0)
                        Text("Summary").tag(1)
                        Text("Words").tag(2)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 350)
                    Spacer()
                    Menu {
                        Button("Smaller Text") { textSize = max(13, textSize - 1) }
                        Button("Larger Text") { textSize = min(24, textSize + 1) }
                        Button("Default Size") { textSize = 16 }
                    } label: { Label("Text Size", systemImage: "textformat.size") }
                        .labelStyle(.iconOnly).accessibilityLabel("Text Size")
                        .menuStyle(.borderlessButton).fixedSize().help("Adjust reading size")
                }.padding(.horizontal, RackLayout.xl).padding(.vertical, RackLayout.l)
                if showPlayer, let player {
                    VideoPlayer(player: player).frame(height: 160).padding(.horizontal, RackLayout.xl)
                        .onReceive(player.currentItem!.publisher(for: \.status)) { status in playbackError = status == .failed }
                    if playbackError {
                        HStack {
                            Text("macOS can't play this format. The transcript is still available.")
                            Button("Show in Finder") { store.reveal(meeting) }
                        }.font(.callout).padding(.horizontal, RackLayout.xl)
                    }
                }
                if tab == 0 {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search this transcript", text: $query)
                            .textFieldStyle(.plain).accessibilityLabel("Search this transcript")
                        if !query.isEmpty { Button("Clear") { query = "" }.buttonStyle(.borderless) }
                    }.padding(RackLayout.s).background(.quaternary, in: RoundedRectangle(cornerRadius: RackLayout.cornerRadius))
                        .padding(.horizontal, RackLayout.xl).padding(.bottom, RackLayout.s)
                    transcript
                } else if tab == 1 { summary }
                else { words }
            } else { processing }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showRename) {
            VStack(alignment: .leading, spacing: RackLayout.l) {
                Text("Rename Transcript").font(.title2.bold())
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showRename = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save Title") { store.rename(meeting, title: title); showRename = false }
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(RackLayout.xl).frame(width: 460)
        }
        .onDisappear { player?.pause() }
    }

    private var isProcessing: Bool { !store.canDelete(meeting) }

    private var header: some View {
        VStack(alignment: .leading, spacing: RackLayout.l) {
            VStack(alignment: .leading, spacing: RackLayout.s) {
                Text(meeting.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                HStack(spacing: RackLayout.m) {
                    Text(meeting.createdAt, style: .date)
                    Label(ScribeFormatters.duration(meeting.durationSeconds), systemImage: "clock").monospacedDigit()
                    Label(meeting.status.displayName, systemImage: statusSymbol)
                        .foregroundStyle(meeting.status == .failed ? Color.red : Color.secondary)
                }.font(.callout).foregroundStyle(.secondary)
                if TranscribeStore.isInFlight(meeting.status) {
                    VStack(alignment: .leading, spacing: RackLayout.s) {
                        ProgressView(value: min(max(meeting.progress, 0), 1))
                        Text("\(meeting.status.displayName) · \(Int((meeting.progress * 100).rounded()))%")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }.frame(maxWidth: 360)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: RackLayout.s) { actions(compact: false) }
                HStack(spacing: RackLayout.s) { actions(compact: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(RackLayout.xl).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }

    private var statusSymbol: String {
        switch meeting.status {
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        default: "waveform"
        }
    }

    /// Compact, content-sized buttons. Menus must be `.fixedSize()` or the bar stretches them to full width.
    @ViewBuilder private func actions(compact: Bool) -> some View {
        Menu {
            ForEach(ScribeExportService.Format.allCases, id: \.self) { format in
                Button(format.title) { export(format) }
                    .disabled((format == .srt || format == .vtt) && !ScribeExportService.hasTimedTranscript(meeting))
            }
        } label: { actionLabel("Export", "square.and.arrow.up", compact) }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.bordered).fixedSize()
            .disabled(meeting.text.isEmpty).help("Export transcript")
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ScribeExportService.transcriptText(meeting), forType: .string)
            copied = true
        } label: { actionLabel(copied ? "Copied" : "Copy Text", copied ? "checkmark" : "doc.on.doc", compact) }
            .buttonStyle(.bordered).fixedSize()
            .disabled(meeting.text.isEmpty).help("Copy transcript text")
        Menu {
            Button(showPlayer ? "Hide Media" : "Play Media") {
                if player == nil { player = AVPlayer(url: URL(filePath: meeting.sourcePath)) }
                showPlayer.toggle()
                if !showPlayer { player?.pause() }
            }.disabled(!FileManager.default.fileExists(atPath: meeting.sourcePath))
            Button("Rename…") { title = meeting.title; showRename = true }
            Button("Show Files in Finder") { store.reveal(meeting) }
        } label: { actionLabel("More", "ellipsis", compact) }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.bordered).fixedSize()
            .help("More actions")
        Spacer(minLength: RackLayout.s)
        Button(role: .destructive) { confirmDelete() } label: { actionLabel("Move to Trash", "trash", compact) }
            .buttonStyle(.bordered).fixedSize()
            .disabled(isProcessing)
            .help(isProcessing ? "In progress. Cancel first to move it to the Trash." : "Move this transcript to the Trash")
    }

    private func confirmDelete() {
        let id = meeting.id
        ScribeDeleteConfirmation.present(title: "Move “\(meeting.title)” to Trash?") { alsoOriginals in
            store.remove(ids: [id], alsoTrashOriginals: alsoOriginals)
        }
    }

    @ViewBuilder private func actionLabel(_ text: String, _ symbol: String, _ compact: Bool) -> some View {
        if compact { Label(text, systemImage: symbol).labelStyle(.iconOnly) }
        else { Label(text, systemImage: symbol).labelStyle(.titleAndIcon) }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RackLayout.xl) {
                if meeting.utterances.isEmpty {
                    if query.isEmpty || meeting.text.localizedCaseInsensitiveContains(query) {
                        Text(meeting.text).textSelection(.enabled)
                    } else { noResults }
                } else {
                    let matches = meeting.utterances.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.speaker.localizedCaseInsensitiveContains(query) }
                    if matches.isEmpty { noResults }
                    ForEach(matches) { utterance in
                        VStack(alignment: .leading, spacing: RackLayout.s) {
                            HStack {
                                Label("Speaker \(utterance.speaker)", systemImage: "person.crop.circle")
                                    .font(.callout.weight(.semibold))
                                Text(ScribeFormatters.timestamp(utterance.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text(utterance.text).textSelection(.enabled)
                        }
                    }
                }
            }.font(.system(size: textSize)).lineSpacing(6)
                .frame(maxWidth: 740, alignment: .leading).padding(RackLayout.xl).frame(maxWidth: .infinity)
        }
    }

    private var noResults: some View {
        ContentUnavailableView("No matches found", systemImage: "magnifyingglass", description: Text("Try another word, or clear the search to see the full transcript."))
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RackLayout.l) {
                if let error = meeting.summaryError {
                    Label("The transcript is saved. The summary isn't ready.", systemImage: "exclamationmark.bubble")
                        .font(.headline)
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Summary Again") { store.retrySummary(meeting) }
                        .disabled(store.isBusy || store.isRecording)
                } else if let summary = meeting.summary, !summary.isEmpty {
                    Text(LocalizedStringKey(summary)).textSelection(.enabled)
                } else {
                    Label("No summary yet", systemImage: "text.alignleft").font(.headline)
                    Text("Generate a summary with decisions and action items using your AssemblyAI account. This feature requires access to the summary model.").foregroundStyle(.secondary)
                    Button("Generate Summary") { store.retrySummary(meeting) }
                        .disabled(store.isBusy || store.isRecording)
                }
            }.font(.system(size: textSize)).lineSpacing(6)
                .frame(maxWidth: 740, alignment: .leading).padding(RackLayout.xl).frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var words: some View {
        Table(meeting.words) {
            TableColumn("Time") { Text(ScribeFormatters.timestamp($0.start)).monospacedDigit() }.width(80)
            TableColumn("Speaker") { Text($0.speaker ?? "Unidentified") }.width(100)
            TableColumn("Word") { Text($0.text).textSelection(.enabled) }
            TableColumn("Confidence") { word in
                Text(word.confidence, format: .percent.precision(.fractionLength(1))).monospacedDigit()
            }.width(90)
        }.overlay {
            if meeting.words.isEmpty { ContentUnavailableView("No word details", systemImage: "textformat.abc", description: Text("The full text is still available on the Transcript tab.")) }
        }
    }

    private var processing: some View {
        VStack(spacing: RackLayout.l) {
            if meeting.status == .failed {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 36))
                Text("Couldn't finish").font(.title2.bold())
                Text(meeting.errorMessage ?? "Try again, or check your connection and API key in Settings.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                Button("Try Again") { store.retry(meeting) }
                    .buttonStyle(.borderedProminent).disabled(store.isBusy || store.isRecording)
            } else {
                ProgressView(value: meeting.progress).frame(maxWidth: 300)
                Text(meeting.status.displayName).font(.title3.bold())
                Text("You can keep browsing the library while you wait.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.padding(RackLayout.xxl).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func export(_ format: ScribeExportService.Format) {
        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.nameFieldStringValue = ScribeExportService.suggestedFilename(meeting: meeting, format: format)
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.contentType]
        panel.presentAsSheet { ok in
            guard ok, let url = panel.url else { return }
            do { try ScribeExportService.export(meeting: meeting, format: format, to: url) }
            catch { store.alertMessage = "Couldn't export. Choose another folder and try again. \(error.localizedDescription)" }
        }
    }
}
