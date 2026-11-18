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
        HSplitView {
            ScribeSidebarView(store: store, openSettings: { showSettings = true })
                .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
            VStack(spacing: 0) {
                ScribeLegacyImportCard(store: store)
                if !store.hasAPIKey && store.isKeyLoaded { apiKeyBanner }
                if let meeting = store.selectedMeeting {
                    ScribeMeetingDetailView(store: store, meeting: meeting).id(meeting.id)
                } else {
                    ScribeEmptyLibraryView(importAction: chooseMedia, recordAction: beginRecording)
                }
            }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if isDropTarget {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 48))
                        Text("Solte os arquivos para transcrever").font(.title2.bold())
                        Text("Áudios e vídeos entram na fila, um de cada vez.")
                    }
                }.padding(12).allowsHitTesting(false).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isDropTarget)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            store.importMedia(urls)
            return true
        } isTargeted: { isDropTarget = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) { activityBar }
        .overlay(alignment: .bottom) { toastLayer }
        .navigationTitle("Transcribe")
        .toolbar {
            ToolbarItemGroup {
                Button(action: chooseMedia) { Label("Importar arquivos", systemImage: "plus") }
                    .help("Importar áudios ou vídeos (⌘O)")
                Button(action: beginRecording) { Label("Gravar", systemImage: "record.circle") }
                    .disabled(store.isBusy || store.isRecording).help("Gravar áudio do Mac e microfone")
                Button { showSettings = true } label: { Label("Ajustes de transcrição", systemImage: "gearshape") }
                    .help("Conta, transcrição e biblioteca")
            }
        }
        .sheet(isPresented: $showRecorder) { ScribeRecordingSetupView(store: store, isPresented: $showRecorder) }
        .sheet(isPresented: $showSettings) { TranscribeSettingsView(store: store, isPresented: $showSettings) }
        .onReceive(NotificationCenter.default.publisher(for: .transcribeImportMedia)) { _ in chooseMedia() }
        .onReceive(NotificationCenter.default.publisher(for: .transcribeNewRecording)) { _ in beginRecording() }
        .onChange(of: store.settingsRequested) { _, requested in
            if requested { showSettings = true; store.settingsRequested = false }
        }
        .environment(\.locale, Locale(identifier: "pt_BR"))
        .alert("Transcribe", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) { Button("OK") { store.alertMessage = nil } } message: { Text(store.alertMessage ?? "") }
        .task { await store.bootstrap() }
    }

    private var apiKeyBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").foregroundStyle(.secondary)
            Text("Conecte sua conta AssemblyAI para começar.").lineLimit(2)
            Spacer(minLength: 8)
            Button("Adicionar API key") { showSettings = true }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.quaternary)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var activityBar: some View {
        if store.isBusy {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(store.activityText).font(.callout).lineLimit(1)
                if store.queuedCount > 0 {
                    Text("\(store.queuedCount) na fila").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                Button(store.queuedCount > 0 ? "Cancelar tudo" : "Cancelar") { store.cancelActiveWork() }
                    .help(store.queuedCount > 0 ? "Cancelar o processamento e esvaziar a fila" : "Cancelar o processamento")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Progresso: \(store.activityText)")
        }
    }

    @ViewBuilder private var toastLayer: some View {
        ZStack {
            if let notice = store.notice {
                ScribeToastView(text: notice.text)
                    .padding(.bottom, store.isBusy ? 64 : 20)
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
        panel.title = "Importar áudios ou vídeos"
        panel.message = "Selecione um ou mais arquivos. Eles serão transcritos em sequência."
        panel.prompt = "Importar"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ScribeMediaProcessor.supportedContentTypes
        // A sheet keeps the window and its tasks alive; an app-modal panel froze the rack while open.
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { store.importMedia(panel.urls) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(panel.runModal()) }
    }
}

private struct ScribeEmptyLibraryView: View {
    let importAction: () -> Void
    let recordAction: () -> Void
    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 56, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Dê voz aos seus arquivos.").font(.largeTitle.weight(.semibold))
                Text("Arraste áudios ou vídeos para cá.\nEncontre cada transcrição nesta biblioteca, quando precisar.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button(action: importAction) { Label("Importar arquivos", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Button(action: recordAction) { Label("Gravar reunião", systemImage: "record.circle") }
            }.controlSize(.large)
            Text("M4A · MP3 · MP4 · OGG · FLAC · WAV · WebM e outros")
                .font(.callout).foregroundStyle(.secondary)
            Text("A mídia é enviada à AssemblyAI para transcrição.\nO histórico e os arquivos ficam neste Mac.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
