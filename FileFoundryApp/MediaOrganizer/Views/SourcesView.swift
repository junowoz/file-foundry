import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    let store: AppStore
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if store.sources.isEmpty {
                RackEmptyState(
                    symbol: "photo.on.rectangle.angled",
                    title: "Organize Your Photos and Videos",
                    message: "Add folders to build a dated library. Your originals are never moved or changed.",
                    primaryTitle: "Add Folders",
                    primarySymbol: "folder.badge.plus",
                    primaryAction: { store.chooseSources() },
                    footnote: "Nothing in your sources is moved, renamed, or deleted."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: RackLayout.m) {
                        RackSectionHeader(title: "Source Folders")
                        List(store.sources) { source in
                            HStack {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(source.displayName)
                                    Text(source.location.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Remove", systemImage: "minus.circle") { store.removeSource(source) }.labelStyle(.iconOnly)
                            }
                        }
                        .frame(minHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: RackLayout.cornerRadius))
                        Button("Add Folders…") { store.chooseSources() }
                            .keyboardShortcut("o", modifiers: .command)
                    }
                    .padding(RackLayout.xl)
                }
            }
            RackStatusBar(status: store.statusMessage, symbol: "lock.fill") {
                HStack(spacing: RackLayout.s) {
                    if store.isWorking { Button("Cancel") { store.cancel() } }
                    Button("Scan") { store.scan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.sources.isEmpty || store.isWorking)
                }
            }
        }
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            store.addSourceURLs(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }
}
