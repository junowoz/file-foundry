import AppKit
import SwiftUI

struct FileCardDetail: Identifiable, Equatable {
    var label: String
    var value: String
    var id: String { label }
}

/// File summary: icon, name, kind and size, plus optional technical details.
struct FileCard: View {
    var url: URL
    var kind: String
    var size: String
    var details: [FileCardDetail] = []
    var isLoading = false
    var onClear: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("\(kind) · \(size)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
                if isLoading { ProgressView().controlSize(.small) }
                if let onClear {
                    Button(action: onClear) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Choose a different file")
                        .accessibilityLabel("Remove file")
                }
            }
            if !details.isEmpty {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(details) { detail in
                        GridRow {
                            Text(detail.label).foregroundStyle(.secondary)
                            Text(detail.value).monospacedDigit().lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .foundryCard()
    }
}

extension View {
    func foundryCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}
