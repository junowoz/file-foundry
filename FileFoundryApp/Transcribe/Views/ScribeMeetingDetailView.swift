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
                    Label(meeting.errorMessage ?? "O texto foi preservado. Tente concluir novamente.", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Tentar concluir") { store.retry(meeting) }.disabled(store.isBusy || store.isRecording)
                }.padding(16).background(.quaternary)
            }
            if !meeting.text.isEmpty || meeting.status == .completed {
                HStack(spacing: 16) {
                    Picker("Conteúdo", selection: $tab) {
                        Text("Transcrição").tag(0)
                        Text("Resumo").tag(1)
                        Text("Palavras").tag(2)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 350)
                    Spacer()
                    Menu {
                        Button("Texto menor") { textSize = max(13, textSize - 1) }
                        Button("Texto maior") { textSize = min(24, textSize + 1) }
                        Button("Tamanho padrão") { textSize = 16 }
                    } label: { Label("Tamanho do texto", systemImage: "textformat.size") }
                        .labelStyle(.iconOnly).accessibilityLabel("Tamanho do texto")
                        .menuStyle(.borderlessButton).fixedSize().help("Ajustar tamanho da leitura")
                }.padding(.horizontal, 24).padding(.vertical, 16)
                if showPlayer, let player {
                    VideoPlayer(player: player).frame(height: 160).padding(.horizontal, 24)
                        .onReceive(player.currentItem!.publisher(for: \.status)) { status in playbackError = status == .failed }
                    if playbackError {
                        HStack {
                            Text("O macOS não reproduz este formato. A transcrição continua disponível.")
                            Button("Abrir no Finder") { store.reveal(meeting) }
                        }.font(.callout).padding(.horizontal, 24)
                    }
                }
                if tab == 0 {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Buscar nesta transcrição", text: $query)
                            .textFieldStyle(.plain).accessibilityLabel("Buscar nesta transcrição")
                        if !query.isEmpty { Button("Limpar") { query = "" }.buttonStyle(.borderless) }
                    }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 24).padding(.bottom, 8)
                    transcript
                } else if tab == 1 { summary }
                else { words }
            } else { processing }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showRename) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Renomear transcrição").font(.title2.bold())
                TextField("Título", text: $title).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancelar") { showRename = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Salvar título") { store.rename(meeting, title: title); showRename = false }
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 460)
        }
        .onDisappear { player?.pause() }
    }

    private var isProcessing: Bool { !store.canDelete(meeting) }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(meeting.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                HStack(spacing: 12) {
                    Text(meeting.createdAt, style: .date)
                    Label(ScribeFormatters.duration(meeting.durationSeconds), systemImage: "clock").monospacedDigit()
                    Label(meeting.status.rawValue, systemImage: statusSymbol)
                        .foregroundStyle(meeting.status == .failed ? Color.red : Color.secondary)
                }.font(.callout).foregroundStyle(.secondary)
                if TranscribeStore.isInFlight(meeting.status) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: min(max(meeting.progress, 0), 1))
                        Text("\(meeting.status.rawValue) · \(Int((meeting.progress * 100).rounded()))%")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }.frame(maxWidth: 360)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions(compact: false) }
                HStack(spacing: 8) { actions(compact: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
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
        } label: { actionLabel("Exportar", "square.and.arrow.up", compact) }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.bordered).fixedSize()
            .disabled(meeting.text.isEmpty).help("Exportar transcrição")
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ScribeExportService.transcriptText(meeting), forType: .string)
            copied = true
        } label: { actionLabel(copied ? "Copiado" : "Copiar texto", copied ? "checkmark" : "doc.on.doc", compact) }
            .buttonStyle(.bordered).fixedSize()
            .disabled(meeting.text.isEmpty).help("Copiar texto da transcrição")
        Menu {
            Button(showPlayer ? "Ocultar mídia" : "Ouvir mídia") {
                if player == nil { player = AVPlayer(url: URL(filePath: meeting.sourcePath)) }
                showPlayer.toggle()
                if !showPlayer { player?.pause() }
            }.disabled(!FileManager.default.fileExists(atPath: meeting.sourcePath))
            Button("Renomear…") { title = meeting.title; showRename = true }
            Button("Mostrar arquivos no Finder") { store.reveal(meeting) }
        } label: { actionLabel("Mais", "ellipsis", compact) }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.bordered).fixedSize()
            .help("Mais ações")
        Spacer(minLength: 8)
        Button(role: .destructive) { confirmDelete() } label: { actionLabel("Excluir", "trash", compact) }
            .buttonStyle(.bordered).fixedSize()
            .disabled(isProcessing)
            .help(isProcessing ? "Em processamento: cancele para excluir" : "Mover esta transcrição para o Lixo")
    }

    private func confirmDelete() {
        let id = meeting.id
        ScribeDeleteConfirmation.present(title: "Excluir “\(meeting.title)”?") { alsoOriginals in
            store.remove(ids: [id], alsoTrashOriginals: alsoOriginals)
        }
    }

    @ViewBuilder private func actionLabel(_ text: String, _ symbol: String, _ compact: Bool) -> some View {
        if compact { Label(text, systemImage: symbol).labelStyle(.iconOnly) }
        else { Label(text, systemImage: symbol).labelStyle(.titleAndIcon) }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if meeting.utterances.isEmpty {
                    if query.isEmpty || meeting.text.localizedCaseInsensitiveContains(query) {
                        Text(meeting.text).textSelection(.enabled)
                    } else { noResults }
                } else {
                    let matches = meeting.utterances.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.speaker.localizedCaseInsensitiveContains(query) }
                    if matches.isEmpty { noResults }
                    ForEach(matches) { utterance in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Pessoa \(utterance.speaker)", systemImage: "person.crop.circle")
                                    .font(.callout.weight(.semibold))
                                Text(ScribeFormatters.timestamp(utterance.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text(utterance.text).textSelection(.enabled)
                        }
                    }
                }
            }.font(.system(size: textSize)).lineSpacing(6)
                .frame(maxWidth: 740, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }
    }

    private var noResults: some View {
        ContentUnavailableView("Nenhum trecho encontrado", systemImage: "magnifyingglass", description: Text("Tente outra palavra ou limpe a busca para ver a transcrição completa."))
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = meeting.summaryError {
                    Label("A transcrição está salva. O resumo não ficou pronto.", systemImage: "exclamationmark.bubble")
                        .font(.headline)
                    Text(error).foregroundStyle(.secondary)
                    Button("Tentar gerar resumo novamente") { store.retrySummary(meeting) }
                        .disabled(store.isBusy || store.isRecording)
                } else if let summary = meeting.summary, !summary.isEmpty {
                    Text(LocalizedStringKey(summary)).textSelection(.enabled)
                } else {
                    Label("Nenhum resumo gerado", systemImage: "text.alignleft").font(.headline)
                    Text("Gere um resumo com decisões e tarefas usando sua conta AssemblyAI. Esse recurso depende do acesso ao modelo de resumo.").foregroundStyle(.secondary)
                    Button("Gerar resumo") { store.retrySummary(meeting) }
                        .disabled(store.isBusy || store.isRecording)
                }
            }.font(.system(size: textSize)).lineSpacing(6)
                .frame(maxWidth: 740, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var words: some View {
        Table(meeting.words) {
            TableColumn("Tempo") { Text(ScribeFormatters.timestamp($0.start)).monospacedDigit() }.width(80)
            TableColumn("Pessoa") { Text($0.speaker ?? "Não identificada") }.width(100)
            TableColumn("Palavra") { Text($0.text).textSelection(.enabled) }
            TableColumn("Confiança") { word in
                Text(word.confidence, format: .percent.precision(.fractionLength(1))).monospacedDigit()
            }.width(90)
        }.overlay {
            if meeting.words.isEmpty { ContentUnavailableView("Sem detalhes por palavra", systemImage: "textformat.abc", description: Text("O texto completo continua disponível na aba Transcrição.")) }
        }
    }

    private var processing: some View {
        VStack(spacing: 20) {
            if meeting.status == .failed {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 36))
                Text("Não foi possível concluir").font(.title2.bold())
                Text(meeting.errorMessage ?? "Tente novamente ou confira sua conexão e a API key nos Ajustes.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                Button("Tentar novamente") { store.retry(meeting) }
                    .buttonStyle(.borderedProminent).disabled(store.isBusy || store.isRecording)
            } else {
                ProgressView(value: meeting.progress).frame(maxWidth: 300)
                Text(meeting.status.rawValue).font(.title3.bold())
                Text("Você pode continuar consultando a biblioteca enquanto aguarda.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func export(_ format: ScribeExportService.Format) {
        let panel = NSSavePanel()
        panel.title = "Exportar transcrição"
        panel.nameFieldStringValue = ScribeExportService.suggestedFilename(meeting: meeting, format: format)
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.contentType]
        if panel.runModal() == .OK, let url = panel.url {
            do { try ScribeExportService.export(meeting: meeting, format: format, to: url) }
            catch { store.alertMessage = "Não foi possível exportar. Escolha outra pasta e tente novamente. \(error.localizedDescription)" }
        }
    }
}
