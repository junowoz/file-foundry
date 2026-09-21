import FileFoundryCore
import SwiftUI

struct DuplicateGroupsView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        Group {
            if viewModel.scanState == .indexing {
                ScanProgressView(state: viewModel.scanState, message: viewModel.statusMessage)
            } else if viewModel.duplicateGroups.isEmpty {
                EmptyStateView(
                    title: "No duplicate groups",
                    message: "Add folders, choose a match mode, and review results before moving anything to Trash."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
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
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(
                                    viewModel.selectedGroupID == group.id
                                        ? Color.accentColor.opacity(0.08)
                                        : Color(nsColor: .controlBackgroundColor)
                                )

                                ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                                    if index > 0 {
                                        Divider()
                                            .padding(.leading, 52)
                                    }

                                    DuplicateFileRowView(
                                        file: file,
                                        reviewState: viewModel.reviewState(for: file, in: group),
                                        allowsRemoval: group.allowsRemoval,
                                        isSelected: viewModel.selectedFileID == file.id,
                                        keepFile: {
                                            viewModel.markFileToKeep(file, in: group)
                                        },
                                        selectFile: {
                                            viewModel.select(file: file, in: group)
                                        }
                                    )
                                }

                                Divider()
                                    .padding(.vertical, 8)
                            }
                            .id(group.id)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}
