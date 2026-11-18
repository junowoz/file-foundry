import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Entry point of the Transcribe rack: library sidebar, transcript detail, activity bar and settings sheet.
struct TranscribeRootView: View {
    @ObservedObject var store: TranscribeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showRecorder = false
    @State private var showSettings = false
    @State private var isDropTarget = false

    init(store: TranscribeStore = .shared) {
        self.store = store
    }

    var body: some View {
        // HSplitView, not NavigationSplitView: this rack already sits in the app's split view, and nesting
        // split views blanks the rack list and duplicates the sidebar column.
        // The status bar is stacked below the split, not added with safeAreaInset: HSplitView is an AppKit view
        // that ignores safe-area insets, so the transcript scrolled underneath the bar and its end was hidden.
        VStack(spacing: 0) {
        HSplitView {
            ScribeSidebarView(store: store, openSettings: { showSettings = true })
                .frame(minWidth: RackLayout.paneMin, idealWidth: RackLayout.paneIdeal, maxWidth: RackLayout.paneMax)
            VStack(spacing: 0) {
                ScribeLegacyImportCard(store: store)
                if !store.hasAPIKey && store.isKeyLoaded { apiKeyBanner }
                if let meeting = store.selectedMeeting {
                    ScribeMeetingDetailView(store: store, meeting: meeting).id(meeting.id)
                } else {
                    RackEmptyState(symbol: "waveform", title: "Transcribe Audio and Video", message: "Drop recordings here or record a meeting. Transcripts stay on this Mac.", primaryTitle: "Import Files", primarySymbol: "plus", primaryAction: chooseMedia, secondaryTitle: "Record Meeting", secondarySymbol: "record.circle", secondaryAction: beginRecording, footnote: "Audio is sent to AssemblyAI for transcription.")
                }
            }.frame(minWidth: RackLayout.contentMin, maxWidth: .infinity, maxHeight: .infinity)
        }
        statusBar
        }
        .overlay {
            if isDropTarget {
                ZStack {
                    RoundedRectangle(cornerRadius: RackLayout.cornerRadius).fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: RackLayout.cornerRadius).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    VStack(spacing: RackLayout.l) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 48))
                        Text("Drop files to transcribe").font(.title2.bold())
                        Text("Audio and video files are queued one at a time.")
                    }
                }.padding(RackLayout.m).allowsHitTesting(false).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isDropTarget)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            store.importMedia(urls)
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay(alignment: .bottom) { toastLayer }
        .navigationTitle("Transcribe")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: chooseMedia) { Label("Import Files", systemImage: "plus") }
                    .help("Import audio or video files (⌘O)")
                Button(action: beginRecording) { Label("Record Meeting", systemImage: "record.circle") }
                    .disabled(store.isBusy || store.isRecording).help("Record system audio and your microphone")
                Button { showSettings = true } label: { Label("Transcribe Options", systemImage: "gearshape") }
                    .help("Account, transcription and library")
            }
        }
        .sheet(isPresented: $showRecorder) { ScribeRecordingSetupView(store: store, isPresented: $showRecorder) }
        .sheet(isPresented: $showSettings) { TranscribeSettingsView(store: store, isPresented: $showSettings) }
        .onReceive(NotificationCenter.default.publisher(for: .transcribeImportMedia)) { _ in chooseMedia() }
        .onReceive(NotificationCenter.default.publisher(for: .transcribeNewRecording)) { _ in beginRecording() }
        .onChange(of: store.settingsRequested) { _, requested in
            if requested { showSettings = true; store.settingsRequested = false }
        }
        .alert("Transcribe", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) { Button("OK") { store.alertMessage = nil } } message: { Text(store.alertMessage ?? "") }
        .task { await store.bootstrap() }
    }

    private var apiKeyBanner: some View {
        HStack(spacing: RackLayout.m) {
            Image(systemName: "key.fill").foregroundStyle(.secondary)
            Text("Connect your AssemblyAI account to get started.").lineLimit(2)
            Spacer(minLength: RackLayout.s)
            Button("Add API Key") { showSettings = true }
        }
        .padding(.horizontal, RackLayout.l).padding(.vertical, RackLayout.m)
        .background(.quaternary)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var statusBar: some View {
        RackStatusBar(status: statusText) {
            if store.isBusy {
                if store.queuedCount > 0 {
                    Text("\(store.queuedCount) queued").foregroundStyle(.secondary)
                }
                Button(store.queuedCount > 0 ? "Cancel All" : "Cancel") { store.cancelActiveWork() }
                    .controlSize(.small)
                    .help(store.queuedCount > 0 ? "Cancel processing and clear the queue" : "Cancel processing")
            }
        }
    }

    private var statusText: String {
        if store.isBusy { return store.activityText }
        let count = store.meetings.count
        return count == 0 ? "Ready" : (count == 1 ? "1 transcript" : "\(count) transcripts")
    }

    @ViewBuilder private var toastLayer: some View {
        ZStack {
            if let notice = store.notice {
                ScribeToastView(text: notice.text)
                    .padding(.bottom, RackLayout.xxl + RackLayout.s)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                    .id(notice.id)
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled { store.dismissNotice() }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.notice?.id)
        .allowsHitTesting(false)
    }

    private func beginRecording() {
        guard !store.isBusy, !store.isRecording else { return }
        if store.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { showSettings = true }
        else { showRecorder = true }
    }

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio or Video"
        panel.message = "Choose one or more files. They are transcribed in order."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ScribeMediaProcessor.supportedContentTypes
        // A sheet keeps the window and its tasks alive; an app-modal panel froze the rack while open.
        panel.presentAsSheet { ok in
            if ok { store.importMedia(panel.urls) }
        }
    }
}
