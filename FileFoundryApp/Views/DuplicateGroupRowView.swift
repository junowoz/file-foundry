import FileFoundryCore
import SwiftUI

struct DuplicateGroupRowView: View {
    var group: DuplicateGroup
    var selectedRemovalCount: Int
    var selectedSavings: Int64

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: group.containsSameUnderlyingFile ? "link" : "doc.on.doc")
                .foregroundStyle(group.containsSameUnderlyingFile ? Color.secondary : Color.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.files.count) matching files")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Label(group.verificationLevel.label, systemImage: group.allowsRemoval ? "checkmark.shield" : "magnifyingglass")
                .font(.caption)
                .foregroundStyle(group.allowsRemoval ? Color.blue : Color.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
    }

    private var summary: String {
        if group.allowsRemoval {
            return "\(selectedRemovalCount) to remove · \(AppFormatters.fileSize(group.size)) each · saves \(AppFormatters.fileSize(selectedSavings))"
        }
        return "Review only. Switch to Identical Content to remove copies."
    }
}
