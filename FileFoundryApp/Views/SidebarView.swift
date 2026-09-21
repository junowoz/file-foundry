import AppKit
import FileFoundryCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: MainViewModel
    @Binding var selectedFolder: URL?
    @State private var showKeepRules = false

    var body: some View {
        VStack(spacing: 0) {
            FolderListView(
                folders: viewModel.folders,
                selectedFolder: $selectedFolder,
                addFolder: chooseFolder,
                removeFolder: { viewModel.removeSelectedFolder(selectedFolder) },
                clearFolders: viewModel.clearFolders
            )

            Button {
                showKeepRules = true
            } label: {
                HStack {
                    Label("Keep Priority", systemImage: "star")
                    Spacer()
                    if !viewModel.options.preferredFolderPaths.isEmpty {
                        Text("\(viewModel.options.preferredFolderPaths.count)")
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .help("Choose which folders win when exact copies are found.")

            Divider()

            ScanOptionsView(options: $viewModel.options)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .sheet(isPresented: $showKeepRules) {
            KeepRulesView(viewModel: viewModel)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add Folder"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            viewModel.addFolder(url)
        }
        selectedFolder = panel.urls.first
    }
}
