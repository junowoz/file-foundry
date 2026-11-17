import AppKit
import SwiftUI

struct ResultPanel: View {
    var outputURL: URL
    var originalBytes: Int?
    var newBytes: Int
    var percentSmaller: Int?
    var warning: String?
    var againTitle: String
    var onAgain: () -> Void

    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(.green)
            if let percentSmaller {
                if percentSmaller > 0 {
                    VStack(spacing: 0) {
                        Text("\(shown)%")
                            .font(.system(size: 56, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(shown)))
                        Text("smaller").font(.title3).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No size savings").font(.title2.weight(.semibold))
                }
            } else {
                Text("Done").font(.title2.weight(.semibold))
            }
            HStack(spacing: 8) {
                if let originalBytes { Text(ByteFormat.string(originalBytes)); Image(systemName: "arrow.right").foregroundStyle(.secondary) }
                Text(ByteFormat.string(newBytes)).fontWeight(.medium)
            }
            .font(.title3).monospacedDigit()
            Text(outputURL.lastPathComponent).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.leading)
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([outputURL]) }
                    .keyboardShortcut(.defaultAction)
                Button(againTitle, action: onAgain)
            }
        }
        .frame(maxWidth: .infinity)
        .foundryCard()
        .task {
            guard let target = percentSmaller else { return }
            if reduceMotion { shown = target; return }
            withAnimation(.spring(response: 0.4, dampingFraction: 1)) { shown = target }
        }
    }
}

struct InlineMessage: View {
    var text: String
    var isError = true
    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle.fill" : "info.circle")
            .font(.callout)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
