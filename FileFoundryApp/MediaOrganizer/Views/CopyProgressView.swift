import SwiftUI

struct CopyProgressView: View {
    let store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: RackLayout.xl) {
                    Image(systemName: "doc.on.doc.fill").font(.system(size: 54)).foregroundStyle(.tint)
                    Text("Creating Your Organized Library").font(.title).fontWeight(.semibold).multilineTextAlignment(.center)
                    ProgressView(value: Double(store.progressCompleted), total: Double(max(store.progressTotal, 1))).frame(maxWidth: 520)
                    Text("\(store.progressCompleted) of \(store.progressTotal) files").monospacedDigit().foregroundStyle(.secondary)
                    Label("Each file is finished only after its source and copy checksums match.", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                }
                .padding(RackLayout.xl)
                .frame(maxWidth: .infinity)
            }
            RackStatusBar(status: store.statusMessage) {
                Button("Cancel Safely") { store.cancel() }.disabled(!store.isWorking)
            }
        }
    }
}
