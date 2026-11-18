import SwiftUI

/// One-time card offering to bring the standalone Meeting Scribe library into File Foundry.
struct ScribeLegacyImportCard: View {
    @ObservedObject var store: TranscribeStore

    private var title: String {
        guard let offer = store.legacyOffer, let count = offer.count, let bytes = offer.bytes else {
            return "Trazer sua biblioteca do Meeting Scribe"
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "Trazer sua biblioteca do Meeting Scribe (\(count) \(count == 1 ? "transcrição" : "transcrições"), \(size))"
    }

    var body: some View {
        if store.legacyOffer != nil || store.importState.isRunning {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    controls
                }
                if case .running(let progress) = store.importState {
                    ProgressView(value: progress)
                }
                if case .failed(let message) = store.importState {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.quaternary)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var detail: String {
        if store.importState.isRunning { return "Copiando para o File Foundry. O Meeting Scribe não é alterado." }
        return "É uma cópia: o Meeting Scribe continua intacto até você apagá-lo. No mesmo volume a cópia é quase instantânea."
    }

    @ViewBuilder private var controls: some View {
        if store.importState.isRunning {
            Button("Cancelar") { store.cancelLegacyImport() }.fixedSize()
        } else {
            HStack(spacing: 8) {
                Button("Agora não") { store.dismissLegacyOffer() }.fixedSize()
                Button("Importar") { store.importLegacyLibrary() }
                    .buttonStyle(.borderedProminent).fixedSize()
                    .disabled(store.isBusy || store.isRecording)
            }
        }
    }
}
