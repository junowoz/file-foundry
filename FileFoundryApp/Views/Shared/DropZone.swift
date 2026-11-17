import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Large drop target that also opens a file picker on click or Space/Return.
struct DropZone: View {
    var title = "Drop a file here"
    var subtitle = "or click to choose"
    var symbol = "square.and.arrow.down"
    var allowsDirectories = true
    var onPick: (URL) -> Void

    @State private var isTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                    .symbolEffect(.bounce, value: isTargeted)
                Text(title).font(.title3.weight(.medium))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(DropZoneButtonStyle(isTargeted: isTargeted))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: isTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in onPick(url) }
            }
            return true
        }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowsDirectories
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { onPick(url) }
    }
}

private struct DropZoneButtonStyle: ButtonStyle {
    var isTargeted: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 5]))
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
    }
}
