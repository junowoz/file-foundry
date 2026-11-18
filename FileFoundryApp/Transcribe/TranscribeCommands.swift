import SwiftUI

extension Notification.Name {
    static let transcribeImportMedia = Notification.Name("FileFoundry.Transcribe.importMedia")
    static let transcribeNewRecording = Notification.Name("FileFoundry.Transcribe.newRecording")
}

/// Menu commands for the Transcribe rack. Add `TranscribeCommands()` to the app's `.commands { }`.
/// The actions are delivered as notifications and handled by `TranscribeRootView` while it is on screen.
struct TranscribeCommands: Commands {
    @ObservedObject private var store = TranscribeStore.shared

    var body: some Commands {
        CommandMenu("Transcrição") {
            Button("Importar mídia…") { NotificationCenter.default.post(name: .transcribeImportMedia, object: nil) }
                .keyboardShortcut("o")
            Button(store.isRecording ? "Encerrar gravação" : "Nova gravação") {
                if store.isRecording { store.stopRecording() }
                else { NotificationCenter.default.post(name: .transcribeNewRecording, object: nil) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
