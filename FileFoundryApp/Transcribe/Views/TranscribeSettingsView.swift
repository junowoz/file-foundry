import SwiftUI

/// In-module settings sheet: account, transcription defaults, advanced options and the library import.
struct TranscribeSettingsView: View {
    @ObservedObject var store: TranscribeStore
    @Binding var isPresented: Bool
    @State private var page = Page.account
    @State private var legacy: TranscribeStore.LegacyOffer?

    enum Page: String, CaseIterable, Identifiable {
        case account = "Account", transcription = "Transcription", advanced = "Advanced"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, RackLayout.l).padding(.top, RackLayout.l).padding(.bottom, RackLayout.m)

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
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }.padding(.horizontal, RackLayout.l).padding(.vertical, RackLayout.m)
        }
        .frame(width: 560, height: 640)
        .onChange(of: store.settings) { _, _ in store.saveSettings() }
        .onDisappear { store.savePreferences() }
        .task { legacy = await store.probeLegacy() }
    }

    // MARK: Conta

    @ViewBuilder private var account: some View {
        Section {
            SecureField("API key", text: $store.apiKey, prompt: Text("Paste your AssemblyAI key"))
            Link("Get an API key from AssemblyAI", destination: URL(string: "https://www.assemblyai.com/dashboard/signup")!)
            HStack(spacing: RackLayout.m) {
                Button("Save Key") { store.savePreferences() }
                Button("Test Connection") { store.savePreferences(); store.validateAPIKey() }
                    .disabled(store.isBusy || store.isRecording || !store.hasAPIKey)
                if store.isBusy { ProgressView().controlSize(.small) }
            }
        } header: { Text("Connect your account") } footer: {
            Text("Transcription uses credits from your AssemblyAI account. Your key is stored in the macOS Keychain.")
        }
        Section {
            Picker("Data region", selection: $store.settings.region) {
                ForEach(AssemblyRegion.allCases) { Text($0.rawValue).tag($0) }
            }
        } header: { Text("Where your data is stored") } footer: {
            Text("Files are sent to AssemblyAI for transcription. History stays on this Mac.")
        }
        librarySection
    }

    @ViewBuilder private var librarySection: some View {
        Section {
            switch store.importState {
            case .running(let progress):
                ProgressView(value: progress) { Text("Copying library…") }
                Button("Cancel Import") { store.cancelLegacyImport() }
            case .done(let text):
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                importButton
            case .idle:
                importButton
            }
        } header: { Text("Meeting Scribe library") } footer: {
            Text("Copies transcripts and files from the Meeting Scribe app. The originals are not changed. Items already here are skipped.")
        }
    }

    @ViewBuilder private var importButton: some View {
        if let legacy {
            Button(legacyTitle(legacy)) { store.importLegacyLibrary() }
                .disabled(store.isBusy || store.isRecording)
        } else {
            Text("No Meeting Scribe library found on this Mac.").foregroundStyle(.secondary)
        }
    }

    private func legacyTitle(_ offer: TranscribeStore.LegacyOffer) -> String {
        guard let count = offer.count, let bytes = offer.bytes else { return "Import Meeting Scribe Library…" }
        return "Import \(count) \(count == 1 ? "Transcript" : "Transcripts") (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
    }

    // MARK: Transcription

    @ViewBuilder private var transcription: some View {
        Section {
            Picker("Model", selection: $store.settings.model) {
                ForEach(SpeechModelChoice.allCases) { Text($0.title).tag($0) }
            }
            TextField("Language", text: $store.settings.languageCode, prompt: Text("Automatic"))
                .multilineTextAlignment(.trailing)
        } header: { Text("Text and language") } footer: {
            Text("Leave empty to detect the language automatically, or enter a code such as en or pt.")
        }
        Section("Speakers") {
            Toggle("Identify speakers", isOn: $store.settings.speakerLabels)
            numberField("Exact number of speakers", $store.settings.expectedSpeakers)
                .disabled(!store.settings.speakerLabels)
            numberField("Minimum speakers", $store.settings.minimumSpeakers)
                .disabled(!store.settings.speakerLabels || store.settings.expectedSpeakers != nil)
            numberField("Maximum speakers", $store.settings.maximumSpeakers)
                .disabled(!store.settings.speakerLabels || store.settings.expectedSpeakers != nil)
            TextField("Known names", text: $store.settings.speakerNames, prompt: Text("Comma-separated"))
                .multilineTextAlignment(.trailing)
                .disabled(!store.settings.speakerLabels)
            Toggle("Multichannel imported audio", isOn: $store.settings.multichannel)
        }
        Section {
            Toggle("Generate summary, decisions, and action items", isOn: $store.settings.generateSummary)
            Toggle("Delete the remote transcript after exporting", isOn: $store.settings.deleteRemoteAfterSave)
        } header: { Text("Summary and privacy") } footer: {
            Text("The summary requires access to the summary model in AssemblyAI. If it fails, the transcript is still available.")
        }
    }

    // MARK: Advanced

    @ViewBuilder private var advanced: some View {
        Section {
            TextField("Meeting context", text: $store.settings.prompt, axis: .vertical).lineLimit(3...8)
            TextField("Important terms", text: $store.settings.keyterms, prompt: Text("Comma-separated"), axis: .vertical).lineLimit(2...6)
            TextField("Custom spelling", text: $store.settings.customSpelling, prompt: Text("variant|variant=Correct"), axis: .vertical).lineLimit(2...6)
        } header: { Text("Vocabulary and context") } footer: {
            Text("Use variant|variant=Correct to set the spelling you want.")
        }
        Section("Text formatting") {
            Picker("Audio events", selection: $store.settings.audioTags) {
                ForEach(AudioTagsChoice.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Automatic punctuation", isOn: $store.settings.punctuate)
            Toggle("Automatic formatting", isOn: $store.settings.formatText)
            Toggle("Keep filler words", isOn: $store.settings.disfluencies)
            Toggle("Filter profanity", isOn: $store.settings.filterProfanity)
        }
        Section("Personal information") {
            Toggle("Redact personal information", isOn: $store.settings.redactPII)
            Picker("Replacement", selection: $store.settings.piiSubstitution) {
                ForEach(PIISubstitution.allCases) { Text($0.title).tag($0) }
            }.disabled(!store.settings.redactPII)
        }
        Section("Additional analysis") {
            Toggle("Detect entities", isOn: $store.settings.entityDetection)
            Toggle("Sentiment analysis", isOn: $store.settings.sentimentAnalysis)
            Toggle("Key phrases", isOn: $store.settings.autoHighlights)
            Toggle("IAB topics", isOn: $store.settings.iabCategories)
            Toggle("Content safety", isOn: $store.settings.contentSafety)
            Toggle("Medical vocabulary", isOn: $store.settings.medicalMode)
        }
        Section {
            numberField("Start (seconds)", $store.settings.audioStartSeconds)
            numberField("End (seconds)", $store.settings.audioEndSeconds)
        } header: { Text("Audio range") } footer: {
            Text("Leave these empty to transcribe the whole file.")
        }
    }

    private func numberField(_ title: String, _ value: Binding<Int?>) -> some View {
        TextField(title, value: value, format: .number, prompt: Text("Optional"))
            .multilineTextAlignment(.trailing)
    }

    private func numberField(_ title: String, _ value: Binding<Double?>) -> some View {
        TextField(title, value: value, format: .number, prompt: Text("Optional"))
            .multilineTextAlignment(.trailing)
    }
}
