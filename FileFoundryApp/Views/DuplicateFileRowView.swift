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
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .disabled(!allowsRemoval)
            .accessibilityLabel(reviewState == .keep ? "Kept copy" : "Keep this copy")
            .help(allowsRemoval ? "Keep this copy and mark the others for Trash" : "Switch to Identical Content to remove copies")

            Button(action: selectFile) {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(file.filename)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            badge
                        }
                        Text(file.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(AppFormatters.fileSize(file.size)) · Modified \(AppFormatters.date(file.modificationDate))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
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
        let (text, color): (String, Color) = switch reviewState {
        case .keep: ("Keep", .green)
        case .remove: ("Trash", .red)
        case .needsReview: (allowsRemoval ? "Needs review" : "Candidate", .orange)
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
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
