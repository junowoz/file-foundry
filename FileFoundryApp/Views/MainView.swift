import AppKit
import FileFoundryCore
import SwiftUI

struct MainView: View {
    @StateObject private var viewModel = MainViewModel()
    @StateObject private var updateViewModel = AppUpdateViewModel()
    @State private var selectedFolder: URL?
    @State private var showTrashConfirmation = false
    @State private var showUpdater = false
    @State private var showPreview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isScanning: Bool { viewModel.scanState == .indexing || viewModel.scanState == .paused }

    var body: some View {
        HSplitView {
            SidebarView(viewModel: viewModel, selectedFolder: $selectedFolder)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
            DuplicateGroupsView(
                viewModel: viewModel,
                addFolders: { FolderPicker.choose(into: viewModel, selection: $selectedFolder) },
                startScan: { viewModel.startScan() }
            )
            .frame(minWidth: 320)
            .inspector(isPresented: $showPreview) {
                FilePreviewView(viewModel: viewModel)
                    .inspectorColumnWidth(min: 240, ideal: 340, max: 480)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                scanControl

                if isScanning {
                    Button {
                        viewModel.cancelScan()
                    } label: {
                        Label("Cancel Scan", systemImage: "xmark")
                    }
                    .help("Cancel the scan")
                }

                Button {
                    showTrashConfirmation = true
                } label: {
                    Label(trashTitle, systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!viewModel.canMoveSelectedFiles)
                .help("Move the selected copies to the Trash. Nothing is deleted permanently.")

                Menu {
                    Button {
                        chooseJSONExport()
                    } label: {
                        Label("Export Audit JSON…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.scanResult == nil)

                    Button {
                        showUpdater = true
                    } label: {
                        Label("Check for Updates…", systemImage: "arrow.down.circle")
                    }

                    Divider()

                    Button {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } label: {
                        Label("Settings…", systemImage: "gearshape")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Export, updates and settings")

                Button {
                    showPreview.toggle()
                } label: {
                    Label("Preview", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide the file preview")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomSummaryBar(viewModel: viewModel)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: viewModel.scanState)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: viewModel.totalDuplicateGroups)
        .onChange(of: viewModel.selectedFileID) { _, newValue in
            // Open the preview the first time something is selected.
            if newValue != nil, !hasAutoOpenedPreview { showPreview = true; hasAutoOpenedPreview = true }
        }
        .alert("Move \(viewModel.totalRemovableFiles) file(s) to Trash?", isPresented: $showTrashConfirmation) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    await viewModel.moveSelectedToTrash()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("About \(AppFormatters.fileSize(viewModel.potentialSavings)) will be reclaimed. Duplicate Finder never deletes files permanently, so you can restore them from the Trash.")
        }
        .sheet(isPresented: $showUpdater) {
            AppUpdateSheetView(viewModel: updateViewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileFoundryShowUpdater)) { _ in
            showUpdater = true
        }
    }

    @State private var hasAutoOpenedPreview = false

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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try viewModel.exportJSON(to: url)
        } catch {
            viewModel.statusMessage = error.localizedDescription
        }
    }
}
