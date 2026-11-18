import AppKit
import FileFoundryCore
import SwiftUI


private enum FoundryModule: String, CaseIterable, Identifiable {
    case duplicates, organizer, media, transcribe, secondScreen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .duplicates: "Duplicate Finder"
        case .organizer: "Media Organizer"
        case .media: "Convert & Compress"
        case .transcribe: "Transcribe"
        case .secondScreen: "Second Screen"
        }
    }
    var symbol: String {
        switch self {
        case .duplicates: "square.stack.3d.up"
        case .organizer: "photo.on.rectangle.angled"
        case .media: "arrow.triangle.2.circlepath"
        case .transcribe: "waveform"
        case .secondScreen: "display.2"
        }
    }
    /// Maps modules saved by older versions (Converter, Compressor) to their new home.
    init(stored: String) {
        switch stored {
        case "converter", "compressor": self = .media
        default: self = FoundryModule(rawValue: stored) ?? .duplicates
        }
    }
}

struct FileFoundryRootView: View {
    let mediaStore: AppStore
    @SceneStorage("selectedModule") private var selectedModule = FoundryModule.duplicates.rawValue

    private var module: Binding<FoundryModule> {
        Binding(
            get: { FoundryModule(stored: selectedModule) },
            set: { selectedModule = $0.rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(FoundryModule.allCases, selection: module) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationTitle("File Foundry")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch module.wrappedValue {
            case .duplicates: MainView()
            case .organizer: ContentView(store: mediaStore)
            case .media: MediaToolView()
            case .transcribe: TranscribeRootView()
            case .secondScreen: SecondScreenView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

