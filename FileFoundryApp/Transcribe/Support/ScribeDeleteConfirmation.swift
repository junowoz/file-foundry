import AppKit

/// Native confirmation for moving transcriptions to the Trash, with the "also trash the original file" checkbox.
/// The checkbox state is remembered under `TranscribeStore.trashOriginalsKey` (default off).
@MainActor
enum ScribeDeleteConfirmation {
    static func present(title: String, completion: @escaping (_ alsoTrashOriginals: Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = "As pastas vão para o Lixo do Mac e podem ser recuperadas de lá."
        let trash = alert.addButton(withTitle: "Mover para o Lixo")
        trash.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancelar")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Também mover o arquivo original para o Lixo"
        alert.suppressionButton?.state = UserDefaults.standard.bool(forKey: TranscribeStore.trashOriginalsKey) ? .on : .off
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let also = alert.suppressionButton?.state == .on
            UserDefaults.standard.set(also, forKey: TranscribeStore.trashOriginalsKey)
            completion(also)
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
