import SwiftUI

/// One-time card offering to bring the standalone Meeting Scribe library into File Foundry.
struct ScribeLegacyImportCard: View {
    @ObservedObject var store: TranscribeStore

    private var title: String {
        guard let offer = store.legacyOffer, let count = offer.count, let bytes = offer.bytes else {
            return "Bring in your Meeting Scribe library"
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "Bring in your Meeting Scribe library (\(count) \(count == 1 ? "transcript" : "transcripts"), \(size))"
    }

    var body: some View {
        if store.legacyOffer != nil || store.importState.isRunning {
            VStack(alignment: .leading, spacing: RackLayout.s) {
                HStack(alignment: .firstTextBaseline, spacing: RackLayout.s) {
                    Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: RackLayout.xs) {
                        Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: RackLayout.m)
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
            .padding(.horizontal, RackLayout.l).padding(.vertical, RackLayout.m)
            .background(.quaternary)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var detail: String {
        if store.importState.isRunning { return "Copying to File Foundry. Meeting Scribe isn't changed." }
        return "This is a copy. Meeting Scribe stays intact until you delete it. On the same drive, the copy is nearly instant."
    }

    @ViewBuilder private var controls: some View {
        if store.importState.isRunning {
            Button("Cancel") { store.cancelLegacyImport() }.fixedSize()
        } else {
            HStack(spacing: RackLayout.s) {
                Button("Not Now") { store.dismissLegacyOffer() }.fixedSize()
                Button("Import") { store.importLegacyLibrary() }
                    .buttonStyle(.borderedProminent).fixedSize()
                    .disabled(store.isBusy || store.isRecording)
            }
        }
    }
}
