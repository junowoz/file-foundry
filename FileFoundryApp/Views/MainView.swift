import AppKit
import FileFoundryCore
import SwiftUI

private enum FoundryModule: String, CaseIterable, Identifiable {
    case duplicates, organizer, converter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .duplicates: "Duplicate Finder"
        case .organizer: "Media Organizer"
        case .converter: "Converter"
        }
    }
    var symbol: String {
        switch self {
        case .duplicates: "square.stack.3d.up"
        case .organizer: "photo.on.rectangle.angled"
        case .converter: "arrow.triangle.2.circlepath"
        }
    }
}

struct FileFoundryRootView: View {
    let mediaStore: AppStore
    @State private var module: FoundryModule = .duplicates

    var body: some View {
        NavigationSplitView {
            List(FoundryModule.allCases, selection: $module) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationTitle("File Foundry")
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                Text("Private, local-first tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }
        } detail: {
            switch module {
            case .duplicates: MainView()
            case .organizer: ContentView(store: mediaStore)
            case .converter: ConverterView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct MainView: View {
    @StateObject private var viewModel = MainViewModel()
    @StateObject private var updateViewModel = AppUpdateViewModel()
    @State private var selectedFolder: URL?
    @State private var showTrashConfirmation = false
    @State private var showUpdater = false

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel, selectedFolder: $selectedFolder)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } content: {
            DuplicateGroupsView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 420, ideal: 640)
        } detail: {
            FilePreviewView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.startScan()
                } label: {
                    Label("Scan", systemImage: "play.fill")
                }
                .disabled(!viewModel.canStartScan)

                Button {
                    viewModel.pauseScan()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .disabled(viewModel.scanState != .indexing)

                Button {
                    viewModel.resumeScan()
                } label: {
                    Label("Resume", systemImage: "forward.fill")
                }
                .disabled(viewModel.scanState != .paused)

                Button {
                    viewModel.cancelScan()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .disabled(viewModel.scanState != .indexing && viewModel.scanState != .paused)
            }

            ToolbarItemGroup {
                Button(role: .destructive) {
                    showTrashConfirmation = true
                } label: {
                    Label("Move selected to Trash", systemImage: "trash")
                }
                .disabled(!viewModel.canMoveSelectedFiles)

                Button {
                    chooseJSONExport()
                } label: {
                    Label("Export Audit JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.scanResult == nil)
                .help("Export all found groups, hashes, paths, and current Keep or Trash selections. Full local paths are included.")

                Button {
                    showUpdater = true
                } label: {
                    Label("Check for Updates", systemImage: "arrow.down.circle")
                }
                .help("Check GitHub Releases and install a verified File Foundry update.")

                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            BottomSummaryBar(viewModel: viewModel)
        }
        .animation(.snappy(duration: 0.22), value: viewModel.scanState)
        .animation(.snappy(duration: 0.22), value: viewModel.totalDuplicateGroups)
        .alert("Selected files will be moved to Trash.", isPresented: $showTrashConfirmation) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    await viewModel.moveSelectedToTrash()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Duplicate Finder never deletes files permanently. Review before moving files.")
        }
        .sheet(isPresented: $showUpdater) {
            AppUpdateSheetView(viewModel: updateViewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileFoundryShowUpdater)) { _ in
            showUpdater = true
        }
    }

    private func chooseJSONExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "file-foundry-audit-report.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try viewModel.exportJSON(to: url)
        } catch {
            viewModel.statusMessage = error.localizedDescription
        }
    }
}
