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
                addFolder: { FolderPicker.choose(into: viewModel, selection: $selectedFolder) },
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
            .padding(.horizontal, RackLayout.l)
            .padding(.vertical, RackLayout.s)
            .frame(minHeight: 32)
            .help("Choose which folders win when identical files are found.")

            Divider()

            ScanOptionsView(options: $viewModel.options)
                .padding(.horizontal, RackLayout.m)
                .padding(.vertical, RackLayout.m)
        }
        .dropDestination(for: URL.self) { urls, _ in
            FolderPicker.drop(urls, into: viewModel)
        }
        .sheet(isPresented: $showKeepRules) {
            KeepRulesView(viewModel: viewModel)
        }
    }
}

enum FolderPicker {
    @MainActor
    static func choose(into viewModel: MainViewModel, selection: Binding<URL?>? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add Folder"

        panel.presentAsSheet { ok in
            guard ok else { return }
            for url in panel.urls {
                viewModel.addFolder(url)
            }
            selection?.wrappedValue = panel.urls.first
        }
    }

    /// Keeps only directories from a drop; files are ignored.
    @MainActor
    static func drop(_ urls: [URL], into viewModel: MainViewModel) -> Bool {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for url in folders { viewModel.addFolder(url) }
        return !folders.isEmpty
    }
}
