import FileFoundryCore
import SwiftUI

struct DuplicateFileRowView: View {
    var file: ScannedFile
    var reviewState: FileReviewState
    var allowsRemoval: Bool
    var isSelected: Bool
    var keepFile: () -> Void
    var selectFile: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: keepFile) {
                Image(systemName: reviewState == .keep ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(reviewState == .keep ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .disabled(!allowsRemoval)
            .help(allowsRemoval ? "Keep this copy and mark the others for Trash" : "Verify with Exact matching before cleanup")

            Button(action: selectFile) {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(file.filename)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            badge
                        }
                        Text(file.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(AppFormatters.fileSize(file.size)) · Modified \(AppFormatters.date(file.modificationDate))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
        .contextMenu {
            if allowsRemoval, reviewState != .keep {
                Button {
                    keepFile()
                } label: {
                    Label("Keep This File", systemImage: "checkmark.circle")
                }
            }
        }
    }

    private var badge: some View {
        Group {
            switch reviewState {
            case .keep:
                Text("Keep")
                    .foregroundStyle(.green)
            case .remove:
                Text("Trash")
                    .foregroundStyle(.red)
            case .needsReview:
                Text(allowsRemoval ? "Needs review" : "Candidate")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2.weight(.semibold))
    }

    private var iconName: String {
        switch file.fileKind {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .folder: "folder"
        case .other: "doc"
        }
    }
}
