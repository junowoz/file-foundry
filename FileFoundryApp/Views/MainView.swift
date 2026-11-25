import AppKit
import FileFoundryCore
import SwiftUI

struct MainView: View {
    @StateObject private var viewModel: MainViewModel
    @State private var selectedFolder: URL?
    @State private var showTrashConfirmation = false
    @State private var showPreview = false
    @State private var hasAutoOpenedPreview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(viewModel: MainViewModel) { _viewModel = StateObject(wrappedValue: viewModel) }

    private var canStartOver: Bool { viewModel.scanState != .movingToTrash && (!viewModel.folders.isEmpty || viewModel.scanResult != nil) }

    var body: some View {
        // Bar stacked below the split: HSplitView ignores safe-area insets, so content would hide under it.
        VStack(spacing: 0) {
        HSplitView {
            SidebarView(viewModel: viewModel, selectedFolder: $selectedFolder)
                .frame(minWidth: RackLayout.paneMin, idealWidth: RackLayout.paneIdeal, maxWidth: RackLayout.paneMax)
            DuplicateGroupsView(
                viewModel: viewModel,
                addFolders: { FolderPicker.choose(into: viewModel, selection: $selectedFolder) },
                startScan: { viewModel.startScan() }
            )
            .frame(minWidth: RackLayout.contentMin)
            .inspector(isPresented: $showPreview) {
                FilePreviewView(viewModel: viewModel)
                    .inspectorColumnWidth(min: 240, ideal: 340, max: 480)
            }
        }
        BottomSummaryBar(viewModel: viewModel)
        }
        .navigationTitle("Duplicate Finder")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                scanControl

                Button {
                    showTrashConfirmation = true
                } label: {
                    Label(trashTitle, systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                // Plain toolbar style with red text: a prominent red fill washed out when disabled in Dark mode.
                .foregroundStyle(viewModel.canMoveSelectedFiles ? Color.red : Color.secondary)
                .disabled(!viewModel.canMoveSelectedFiles)
                .help("Move the selected copies to the Trash. You can restore them from the Trash.")

                Button {
                    viewModel.cancelScan()
                    viewModel.clearFolders()
                    selectedFolder = nil
                    showPreview = false
                    hasAutoOpenedPreview = false
                    viewModel.scanState = .idle
                } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
                .disabled(!canStartOver)
                .help("Stop the scan and clear the folders and results")

                Button {
                    showPreview.toggle()
                } label: {
                    Label("Preview", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide the file preview")

                Menu {
                    Button {
                        chooseJSONExport()
                    } label: {
                        Label("Export Report…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.scanResult == nil)

                    Divider()

                    Button {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } label: {
                        Label("Settings…", systemImage: "gearshape")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Export and settings")
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: viewModel.scanState)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: viewModel.totalDuplicateGroups)
        .onChange(of: viewModel.selectedFileID) { _, newValue in
            // Open the preview the first time something is selected.
            if newValue != nil, !hasAutoOpenedPreview { showPreview = true; hasAutoOpenedPreview = true }
        }
        .alert(
            "Move \(viewModel.totalRemovableFiles) \(viewModel.totalRemovableFiles == 1 ? "File" : "Files") to Trash?",
            isPresented: $showTrashConfirmation
        ) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    await viewModel.moveSelectedToTrash()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("About \(AppFormatters.fileSize(viewModel.potentialSavings)) will be freed. You can restore the files from the Trash.")
        }
    }

    private var trashTitle: String {
        viewModel.totalRemovableFiles > 0 ? "Move to Trash (\(viewModel.totalRemovableFiles))" : "Move to Trash"
    }

    /// One stateful control: Scan, Pause or Resume depending on the scan state.
    @ViewBuilder
    private var scanControl: some View {
        switch viewModel.scanState {
        case .indexing:
            Button { viewModel.pauseScan() } label: { Label("Pause", systemImage: "pause.fill") }
                .help("Pause the scan")
        case .paused:
            Button { viewModel.resumeScan() } label: { Label("Resume", systemImage: "play.fill") }
                .help("Resume the scan")
        default:
            Button { viewModel.startScan() } label: { Label("Scan", systemImage: "play.fill") }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!viewModel.canStartScan)
                .help("Scan the selected folders for duplicates")
        }
    }

    private func chooseJSONExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "file-foundry-audit-report.json"
        panel.canCreateDirectories = true
        panel.presentAsSheet { ok in
            guard ok, let url = panel.url else { return }
            do {
                try viewModel.exportJSON(to: url)
            } catch {
                viewModel.statusMessage = error.localizedDescription
            }
        }
    }
}
