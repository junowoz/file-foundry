import AppKit
import FileFoundryCore
import SwiftUI

struct KeepRulesView: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Keep Priority", systemImage: "star.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            List {
                ForEach(Array(viewModel.options.preferredFolderPaths.enumerated()), id: \.element) { index, path in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28)

                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .fontWeight(.medium)
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Button {
                            viewModel.movePreferredFolder(from: index, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .disabled(index == 0)
                        .help("Move up")

                        Button {
                            viewModel.movePreferredFolder(from: index, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .disabled(index == viewModel.options.preferredFolderPaths.count - 1)
                        .help("Move down")

                        Button(role: .destructive) {
                            viewModel.removePreferredFolder(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Remove location")
                    }
                    .padding(.vertical, 6)
                }
            }
            .overlay {
                if viewModel.options.preferredFolderPaths.isEmpty {
                    ContentUnavailableView("No Keep Locations", systemImage: "star")
                }
            }

            Divider()

            HStack {
                Text("Highest priority first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    chooseFolder()
                } label: {
                    Label("Add Location", systemImage: "folder.badge.plus")
                }
            }
            .padding(16)
        }
        .frame(minWidth: 640, minHeight: 430)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add Location"

        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(viewModel.addPreferredFolder)
    }
}
