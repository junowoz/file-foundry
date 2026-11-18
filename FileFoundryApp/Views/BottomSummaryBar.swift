import FileFoundryCore
import SwiftUI

/// Bottom status bar of Duplicate Finder: current status on the left, scan counts on the right.
struct BottomSummaryBar: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        RackStatusBar(status: viewModel.statusMessage, symbol: nil) {
            HStack(spacing: RackLayout.l) {
                stat("Reclaimable", AppFormatters.fileSize(viewModel.potentialSavings))
                stat("Files", "\(viewModel.totalScannedFiles)")
                stat("Groups", "\(viewModel.totalDuplicateGroups)")
                stat("Selected", "\(viewModel.totalRemovableFiles)")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: RackLayout.xs) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
    }
}
