import FileFoundryCore
import SwiftUI

struct ScanProgressView: View {
    var state: ScanState
    var message: String
    var currentFile: String = ""
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            // The scan service reports phases, not item counts, so the bar is honest: indeterminate.
            ProgressView()
                .progressViewStyle(.linear)
                .frame(maxWidth: 280)
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(currentFile.isEmpty ? message : currentFile)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360)
            }
            if let onCancel {
                Button("Cancel", role: .cancel, action: onCancel)
                    .controlSize(.regular)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch state {
        case .paused: "Scan paused"
        case .groupingBySize: "Grouping by size"
        case .partialHashing: "Sampling content"
        case .fullHashing: "Checking contents"
        case .byteComparing: "Comparing files"
        default: "Scanning folders"
        }
    }
}
