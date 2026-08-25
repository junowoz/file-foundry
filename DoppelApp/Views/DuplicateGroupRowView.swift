import DoppelCore
import SwiftUI

struct DuplicateGroupRowView: View {
    var group: DuplicateGroup
    var selectedRemovalCount: Int
    var selectedSavings: Int64

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: group.containsSameUnderlyingFile ? "link" : "doc.on.doc")
                .foregroundStyle(group.containsSameUnderlyingFile ? .gray : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(group.files.count) matching files")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(group.verificationLevel.label, systemImage: group.allowsRemoval ? "checkmark.shield" : "magnifyingglass")
                .font(.caption)
                .foregroundStyle(group.allowsRemoval ? .blue : .secondary)
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        if group.allowsRemoval {
            return "\(selectedRemovalCount) removable · \(AppFormatters.fileSize(group.size)) each · saves \(AppFormatters.fileSize(selectedSavings))"
        }
        return "Review only · verify with Exact matching before cleanup"
    }
}
