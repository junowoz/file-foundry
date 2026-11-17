import FileFoundryCore
import SwiftUI

struct BottomSummaryBar: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(showFiles: true, showStatus: true)
            bar(showFiles: false, showStatus: true)
            bar(showFiles: false, showStatus: false)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func bar(showFiles: Bool, showStatus: Bool) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .foregroundStyle(.green)
                Text("Reclaimable")
                    .foregroundStyle(.secondary)
                Text(AppFormatters.fileSize(viewModel.potentialSavings))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            if showFiles {
                stat("Files", viewModel.totalScannedFiles)
            }
            stat("Groups", viewModel.totalDuplicateGroups)
            stat("Selected", viewModel.totalRemovableFiles)
            Spacer(minLength: 8)
            if showStatus {
                Text(viewModel.statusMessage)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: !showStatus, vertical: false)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text("\(value)").fontWeight(.medium).monospacedDigit()
        }
    }
}
