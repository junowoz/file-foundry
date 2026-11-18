import SwiftUI

/// In-module settings sheet: account, transcription defaults, advanced options and the library import.
struct TranscribeSettingsView: View {
    @ObservedObject var store: TranscribeStore
    @Binding var isPresented: Bool
    @State private var page = Page.account
    @State private var legacy: TranscribeStore.LegacyOffer?

    enum Page: String, CaseIterable, Identifiable {
        case account = "Conta", transcription = "Transcrição", advanced = "Avançado"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Seção", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)

            Form {
                switch page {
                case .account: account
                case .transcription: transcription
                case .advanced: advanced
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Concluído") { isPresented = false }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560, height: 640)
        .onChange(of: store.settings) { _, _ in store.saveSettings() }
        .onDisappear { store.savePreferences() }
        .task { legacy = await store.probeLegacy() }
    }

    // MARK: Conta

    @ViewBuilder private var account: some View {
        Section {
            SecureField("API key", text: $store.apiKey, prompt: Text("Cole a chave da AssemblyAI"))
            Link("Obter API key na AssemblyAI", destination: URL(string: "https://www.assemblyai.com/dashboard/signup")!)
            HStack(spacing: 12) {
                Button("Salvar chave") { store.savePreferences() }
                Button("Testar conexão") { store.savePreferences(); store.validateAPIKey() }
                    .disabled(store.isBusy || store.isRecording || !store.hasAPIKey)
                if store.isBusy { ProgressView().controlSize(.small) }
            }
        } header: { Text("Conecte sua conta") } footer: {
            Text("A transcrição usa o saldo da sua conta AssemblyAI. A chave fica protegida no Keychain do macOS.")
        }
        Section {
            Picker("Região dos dados", selection: $store.settings.region) {
                ForEach(AssemblyRegion.allCases) { Text($0.rawValue).tag($0) }
            }
        } header: { Text("Onde seus dados ficam") } footer: {
            Text("Os arquivos são enviados à AssemblyAI para transcrição. O histórico fica neste Mac.")
        }
        librarySection
    }

    @ViewBuilder private var librarySection: some View {
        Section {
            switch store.importState {
            case .running(let progress):
                ProgressView(value: progress) { Text("Copiando biblioteca…") }
                Button("Cancelar importação") { store.cancelLegacyImport() }
            case .done(let text):
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                importButton
            case .idle:
                importButton
            }
        } header: { Text("Biblioteca do Meeting Scribe") } footer: {
            Text("Copia as transcrições e arquivos do app Meeting Scribe sem alterar o original. Itens que já estão aqui são ignorados.")
        }
    }

    @ViewBuilder private var importButton: some View {
        if let legacy {
            Button(legacyTitle(legacy)) { store.importLegacyLibrary() }
                .disabled(store.isBusy || store.isRecording)
        } else {
            Text("Nenhuma biblioteca do Meeting Scribe encontrada neste Mac.").foregroundStyle(.secondary)
        }
    }

    private func legacyTitle(_ offer: TranscribeStore.LegacyOffer) -> String {
        guard let count = offer.count, let bytes = offer.bytes else { return "Importar biblioteca do Meeting Scribe…" }
        return "Importar \(count) \(count == 1 ? "transcrição" : "transcrições") (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
    }

    // MARK: Transcrição

    @ViewBuilder private var transcription: some View {
        Section {
            Picker("Modelo", selection: $store.settings.model) {
                ForEach(SpeechModelChoice.allCases) { Text($0.title).tag($0) }
            }
            TextField("Idioma", text: $store.settings.languageCode, prompt: Text("Automático"))
                .multilineTextAlignment(.trailing)
        } header: { Text("Texto e idioma") } footer: {
            Text("Deixe o idioma vazio para detectar automaticamente ou use pt para português.")
        }
        Section("Participantes") {
            Toggle("Separar locutores", isOn: $store.settings.speakerLabels)
            numberField("Número exato de locutores", $store.settings.expectedSpeakers)
                .disabled(!store.settings.speakerLabels)
            numberField("Mínimo de locutores", $store.settings.minimumSpeakers)
                .disabled(!store.settings.speakerLabels || store.settings.expectedSpeakers != nil)
            numberField("Máximo de locutores", $store.settings.maximumSpeakers)
                .disabled(!store.settings.speakerLabels || store.settings.expectedSpeakers != nil)
            TextField("Nomes conhecidos", text: $store.settings.speakerNames, prompt: Text("Separados por vírgula"))
                .multilineTextAlignment(.trailing)
                .disabled(!store.settings.speakerLabels)
            Toggle("Áudio multicanal importado", isOn: $store.settings.multichannel)
        }
        Section {
            Toggle("Gerar resumo, decisões e tarefas", isOn: $store.settings.generateSummary)
            Toggle("Apagar a transcrição remota depois de exportar", isOn: $store.settings.deleteRemoteAfterSave)
        } header: { Text("Resumo e privacidade") } footer: {
            Text("O resumo exige acesso ao modelo de resumo na AssemblyAI. Se falhar, a transcrição continua disponível.")
        }
    }

    // MARK: Avançado

    @ViewBuilder private var advanced: some View {
        Section {
            TextField("Contexto da reunião", text: $store.settings.prompt, axis: .vertical).lineLimit(3...8)
            TextField("Termos importantes", text: $store.settings.keyterms, prompt: Text("Separados por vírgula"), axis: .vertical).lineLimit(2...6)
            TextField("Grafias personalizadas", text: $store.settings.customSpelling, prompt: Text("variante|variante=Correto"), axis: .vertical).lineLimit(2...6)
        } header: { Text("Vocabulário e contexto") } footer: {
            Text("Use variante|variante=Correto para indicar a grafia desejada.")
        }
        Section("Formatação do texto") {
            Picker("Eventos de áudio", selection: $store.settings.audioTags) {
                ForEach(AudioTagsChoice.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Pontuação automática", isOn: $store.settings.punctuate)
            Toggle("Formatação automática", isOn: $store.settings.formatText)
            Toggle("Preservar hesitações", isOn: $store.settings.disfluencies)
            Toggle("Filtrar palavrões", isOn: $store.settings.filterProfanity)
        }
        Section("Dados pessoais") {
            Toggle("Ocultar dados pessoais", isOn: $store.settings.redactPII)
            Picker("Substituição", selection: $store.settings.piiSubstitution) {
                ForEach(PIISubstitution.allCases) { Text($0.title).tag($0) }
            }.disabled(!store.settings.redactPII)
        }
        Section("Análises adicionais") {
            Toggle("Detectar entidades", isOn: $store.settings.entityDetection)
            Toggle("Análise de sentimento", isOn: $store.settings.sentimentAnalysis)
            Toggle("Frases-chave", isOn: $store.settings.autoHighlights)
            Toggle("Tópicos IAB", isOn: $store.settings.iabCategories)
            Toggle("Classificação de segurança", isOn: $store.settings.contentSafety)
            Toggle("Vocabulário médico", isOn: $store.settings.medicalMode)
        }
        Section {
            numberField("Início (segundos)", $store.settings.audioStartSeconds)
            numberField("Fim (segundos)", $store.settings.audioEndSeconds)
        } header: { Text("Trecho do áudio") } footer: {
            Text("Deixe os campos vazios para transcrever o arquivo inteiro.")
        }
    }

    private func numberField(_ title: String, _ value: Binding<Int?>) -> some View {
        TextField(title, value: value, format: .number, prompt: Text("Opcional"))
            .multilineTextAlignment(.trailing)
    }

    private func numberField(_ title: String, _ value: Binding<Double?>) -> some View {
        TextField(title, value: value, format: .number, prompt: Text("Opcional"))
            .multilineTextAlignment(.trailing)
    }
}
