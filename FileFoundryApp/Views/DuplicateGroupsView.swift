import FileFoundryCore
import SwiftUI

struct DuplicateGroupsView: View {
    @ObservedObject var viewModel: MainViewModel
    var addFolders: () -> Void
    var startScan: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false

    private var isScanning: Bool {
        viewModel.scanState == .indexing || viewModel.scanState == .paused
    }

    var body: some View {
        Group {
            if isScanning {
                ScanProgressView(
                    state: viewModel.scanState,
                    message: viewModel.statusMessage,
                    currentFile: viewModel.currentFileDescription,
                    onCancel: { viewModel.cancelScan() }
                )
            } else if viewModel.duplicateGroups.isEmpty {
                emptyState
            } else {
                groupList
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: RackLayout.cornerRadius)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: RackLayout.cornerRadius))
                    .padding(RackLayout.s)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            FolderPicker.drop(urls, into: viewModel)
        } isTargeted: { isDropTargeted = $0 }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.folders.isEmpty {
            RackEmptyState(
                symbol: "square.stack.3d.up",
                title: "Find Duplicate Files",
                message: "Add a folder to find files with identical content. Nothing is removed until you confirm.",
                primaryTitle: "Add Folder",
                primaryAction: addFolders
            )
        } else if viewModel.scanState == .finished {
            RackEmptyState(
                symbol: "checkmark.seal",
                title: "No Duplicates Found",
                message: "No matching files were found in the selected folders."
            )
        } else {
            let count = viewModel.folders.count
            RackEmptyState(
                symbol: "magnifyingglass",
                title: "Ready to Scan",
                message: "\(count) \(count == 1 ? "folder" : "folders") selected. Adjust the options in the sidebar, then scan.",
                primaryTitle: viewModel.canStartScan ? "Scan" : nil,
                primarySymbol: "play.fill",
                primaryAction: viewModel.canStartScan ? startScan : nil
            )
        }
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(viewModel.duplicateGroups) { group in
                    VStack(spacing: 0) {
                        Button {
                            viewModel.select(group: group)
                        } label: {
                            DuplicateGroupRowView(
                                group: group,
                                selectedRemovalCount: viewModel.selectedRemovalCount(in: group),
                                selectedSavings: viewModel.selectedSavings(in: group)
                            )
                            .padding(.horizontal, RackLayout.l)
                            .padding(.vertical, RackLayout.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            viewModel.selectedGroupID == group.id
                                ? Color.accentColor.opacity(0.10)
                                : Color(nsColor: .controlBackgroundColor)
                        )

                        ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                            if index > 0 {
                                Divider().padding(.leading, 56)
                            }
                            DuplicateFileRowView(
                                file: file,
                                reviewState: viewModel.reviewState(for: file, in: group),
                                allowsRemoval: group.allowsRemoval,
                                isSelected: viewModel.selectedFileID == file.id,
                                keepFile: { viewModel.markFileToKeep(file, in: group) },
                                selectFile: { viewModel.select(file: file, in: group) }
                            )
                        }

                        Divider().padding(.top, RackLayout.s)
                    }
                    .id(group.id)
                }
            }
        }
    }
}
