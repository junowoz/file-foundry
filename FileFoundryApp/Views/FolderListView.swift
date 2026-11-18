import SwiftUI

struct FolderListView: View {
    var folders: [URL]
    @Binding var selectedFolder: URL?
    var addFolder: () -> Void
    var removeFolder: () -> Void
    var clearFolders: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedFolder) {
                Section("Folders") {
                    if folders.isEmpty {
                        Text("Drop folders here or click Add.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(folders, id: \.self) { folder in
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                            .tag(folder as URL?)
                            .help(folder.path)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 72, idealHeight: 160, maxHeight: 240)

            HStack(spacing: 8) {
                Button(action: addFolder) {
                    Label("Add Folder", systemImage: "plus")
                }
                .help("Add folders to scan")
                Button(action: removeFolder) {
                    Label("Remove Folder", systemImage: "minus")
                }
                .disabled(selectedFolder == nil)
                .help("Remove the selected folder")
                Button(action: clearFolders) {
                    Label("Clear All", systemImage: "trash.slash")
                }
                .disabled(folders.isEmpty)
                .help("Remove all folders")
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(8)
        }
    }
}
