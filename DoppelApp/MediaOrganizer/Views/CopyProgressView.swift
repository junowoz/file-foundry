import SwiftUI

struct CopyProgressView: View {
    let store: AppStore
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "doc.on.doc.fill").font(.system(size: 54)).foregroundStyle(.tint)
            Text("Criando a biblioteca organizada").font(.largeTitle).fontWeight(.semibold)
            Text(store.statusMessage).foregroundStyle(.secondary)
            ProgressView(value: Double(store.progressCompleted), total: Double(max(store.progressTotal, 1))).frame(maxWidth: 520)
            Text("\(store.progressCompleted) de \(store.progressTotal) arquivos").monospacedDigit()
            Button("Cancelar com segurança") { store.cancel() }.disabled(!store.isWorking)
            Label("Cada arquivo só é finalizado após SHA-256 da origem e da cópia coincidirem.", systemImage: "checkmark.shield").foregroundStyle(.secondary)
            Spacer()
        }.padding()
    }
}
