import AppKit
import FileFoundryCore
import SwiftUI

enum FoundryModule: String, CaseIterable, Identifiable {
    case home, duplicates, organizer, media, transcribe, secondScreen, cleaner
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .duplicates: "Duplicate Finder"
        case .organizer: "Media Organizer"
        case .media: "Convert & Compress"
        case .transcribe: "Transcribe"
        case .secondScreen: "Second Screen"
        case .cleaner: "App Cleaner"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .duplicates: "square.on.square"
        case .organizer: "photo.stack"
        case .media: "arrow.triangle.2.circlepath"
        case .transcribe: "waveform"
        case .secondScreen: "rectangle.on.rectangle"
        case .cleaner: "trash"
        }
    }
    /// What each rack does, shown on the Home screen.
    var summary: String {
        switch self {
        case .home: ""
        case .duplicates: "Find files with identical content and move extra copies to the Trash."
        case .organizer: "Sort photos and videos into folders by date."
        case .media: "Convert and compress video, audio and images, including SVG to PNG."
        case .transcribe: "Record or import meetings and turn them into searchable transcripts."
        case .secondScreen: "Use an Android tablet or phone as a second display."
        case .cleaner: "Uninstall apps together with their leftovers, safely."
        }
    }

    /// Racks shown as tools; Home is the start screen, not a tool.
    static var tools: [FoundryModule] { allCases.filter { $0 != .home } }

    /// Maps modules saved by older versions (Converter, Compressor) to their new home.
    init(stored: String) {
        switch stored {
        case "converter", "compressor": self = .media
        default: self = FoundryModule(rawValue: stored) ?? .home
        }
    }

    /// Applies a saved comma-separated order. Unknown and repeated values are dropped,
    /// old names are migrated, and racks missing from the list are appended in default order.
    static func ordered(from stored: String) -> [FoundryModule] {
        var result: [FoundryModule] = []
        for raw in stored.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let module: FoundryModule
            switch raw {
            case "converter", "compressor": module = .media
            default:
                guard let known = FoundryModule(rawValue: raw), known != .home else { continue }
                module = known
            }
            if !result.contains(module) { result.append(module) }
        }
        for module in tools where !result.contains(module) { result.append(module) }
        return result
    }

    static func serialize(_ modules: [FoundryModule]) -> String {
        modules.map(\.rawValue).joined(separator: ",")
    }
}

struct FileFoundryRootView: View {
    let mediaStore: AppStore
    @SceneStorage("selectedModule") private var selectedModule = FoundryModule.home.rawValue
    @AppStorage("rackOrder") private var rackOrder = ""
    @AppStorage(AppUpdateViewModel.autoCheckDefaultsKey) private var autoCheckForUpdates = true
    @StateObject private var updateViewModel = AppUpdateViewModel()
    @State private var showUpdater = false

    private var module: Binding<FoundryModule> {
        Binding(
            get: { FoundryModule(stored: selectedModule) },
            set: { selectedModule = $0.rawValue })
    }

    private var orderedModules: [FoundryModule] { FoundryModule.ordered(from: rackOrder) }

    var body: some View {
        NavigationSplitView {
            List(selection: module) {
                Label(FoundryModule.home.title, systemImage: FoundryModule.home.symbol)
                    .labelStyle(SidebarRackLabelStyle())
                    .tag(FoundryModule.home)
                ForEach(orderedModules) { item in
                    Label(item.title, systemImage: item.symbol)
                        .labelStyle(SidebarRackLabelStyle())
                        .tag(item)
                        .contextMenu {
                            Button("Reset Order") { rackOrder = "" }
                                .disabled(rackOrder.isEmpty)
                        }
                }
                .onMove { source, destination in
                    var modules = orderedModules
                    modules.move(fromOffsets: source, toOffset: destination)
                    rackOrder = FoundryModule.serialize(modules)
                }
            }
            .navigationTitle("File Foundry")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch module.wrappedValue {
            case .home: HomeView(open: { module.wrappedValue = $0 })
            case .duplicates: MainView()
            case .organizer: ContentView(store: mediaStore)
            case .media: MediaToolView()
            case .transcribe: TranscribeRootView()
            case .secondScreen: SecondScreenView()
            case .cleaner: AppCleanerRootView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if let release = updateViewModel.availableRelease {
                    Button {
                        showUpdater = true
                    } label: {
                        Text("Update Available")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Version \(release.version) is ready to install")
                    .accessibilityLabel("Update Available, version \(release.version)")
                }
            }
        }
        .sheet(isPresented: $showUpdater) {
            AppUpdateSheetView(viewModel: updateViewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileFoundryShowUpdater)) { _ in
            showUpdater = true
        }
        .task {
            // Silent check at launch, then at most once every 24 hours while the app stays open.
            while !Task.isCancelled {
                if autoCheckForUpdates {
                    await updateViewModel.checkSilentlyIfDue()
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }
}


/// Sidebar row: every symbol sits in the same fixed-width column, so the titles line up
/// and wide symbols never touch the text.
private struct SidebarRackLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .font(.system(size: 14, weight: .regular))
                .imageScale(.medium)
                .frame(width: 22, alignment: .center)
                .foregroundStyle(.tint)
            configuration.title
                .lineLimit(1)
        }
    }
}


/// Start screen: one card per rack.
struct HomeView: View {
    let open: (FoundryModule) -> Void
    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("File Foundry").font(.largeTitle.weight(.semibold))
                    Text("Choose a tool to get started.").font(.title3).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(FoundryModule.tools) { item in
                        Button { open(item) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 22))
                                    .foregroundStyle(.tint)
                                    .frame(height: 28, alignment: .leading)
                                Text(item.title).font(.headline)
                                Text(item.summary)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens \(item.title)")
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Home")
    }
}
