import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    let store: AppStore
    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 20)
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 52)).foregroundStyle(.tint)
                Text("Arraste suas pastas de mídia").font(.largeTitle).fontWeight(.semibold)
                Text("Fotos, vídeos, áudios e outros arquivos serão analisados sem alterar os originais.")
                    .foregroundStyle(.secondary)
                Button("Adicionar pastas…") { store.chooseSources() }
                    .buttonStyle(.borderedProminent).keyboardShortcut("o", modifiers: .command)
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(style: StrokeStyle(lineWidth: 1, dash: [7])).foregroundStyle(.tertiary))
            .dropDestination(for: URL.self) { urls, _ in store.addSourceURLs(urls); return !urls.isEmpty }

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
            }
            HStack {
                Label("Nenhum arquivo da origem será movido, renomeado ou apagado.", systemImage: "lock.fill").foregroundStyle(.secondary)
                Spacer()
                if store.isWorking { Button("Cancelar") { store.cancel() } }
                Button("Escanear") { store.scan() }
                    .buttonStyle(.borderedProminent).disabled(store.sources.isEmpty || store.isWorking)
            }
            Spacer(minLength: 10)
        }
        .padding(28)
    }
}
