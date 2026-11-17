import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    let store: AppStore
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
            VStack(spacing: 16) {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 52)).foregroundStyle(.tint)
                Text("Arraste suas pastas de mídia").font(.title).multilineTextAlignment(.center).fontWeight(.semibold)
                Text("Fotos, vídeos, áudios e outros arquivos serão analisados sem alterar os originais.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Adicionar pastas…") { store.chooseSources() }
                    .buttonStyle(.borderedProminent).keyboardShortcut("o", modifiers: .command)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [7])).foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
            .dropDestination(for: URL.self) { urls, _ in store.addSourceURLs(urls); return !urls.isEmpty } isTargeted: { isDropTargeted = $0 }

            if !store.sources.isEmpty {
                List(store.sources) { source in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(source.displayName)
                            Text(source.location.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Remover", systemImage: "minus.circle") { store.removeSource(source) }.labelStyle(.iconOnly)
                    }
                }
                .frame(minHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            }
            }
            HStack {
                Label("Nenhum arquivo da origem será movido, renomeado ou apagado.", systemImage: "lock.fill").foregroundStyle(.secondary).font(.callout).lineLimit(2)
                Spacer(minLength: 8)
                if store.isWorking { Button("Cancelar") { store.cancel() } }
                Button("Escanear") { store.scan() }
                    .buttonStyle(.borderedProminent).disabled(store.sources.isEmpty || store.isWorking)
            }
        }
        .padding(24)
    }
}
