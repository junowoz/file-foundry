import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drop target that also opens a file picker on click or Space/Return. Accepts several files at once.
struct DropZone: View {
    var title = "Drop files here"
    var subtitle = "or click to choose"
    var symbol = "square.and.arrow.down"
    var allowsDirectories = true
    /// A slim one-line strip, used to add more files once the list is showing.
    var compact = false
    var onPick: ([URL]) -> Void

    @State private var isTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: choose) {
            Group {
                if compact {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                        Text(title).font(.callout.weight(.medium))
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: symbol)
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                            .symbolEffect(.bounce, value: isTargeted)
                        Text(title).font(.title3.weight(.medium))
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 216)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(DropZoneButtonStyle(isTargeted: isTargeted, radius: compact ? 12 : 16))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: isTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            let collector = URLCollector(expected: providers.count)
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let urls = collector.add(url) { Task { @MainActor in onPick(urls) } }
                }
            }
            return !providers.isEmpty
        }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowsDirectories
        panel.allowsMultipleSelection = true
        panel.presentAsSheet { ok in
            guard ok, !panel.urls.isEmpty else { return }
            onPick(panel.urls)
        }
    }
}

/// Gathers the URLs from several asynchronous item-provider callbacks and reports once, in drop order.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int

    init(expected: Int) { remaining = expected }

    /// Returns the full list when the last callback arrives, nil before that.
    func add(_ url: URL?) -> [URL]? {
        lock.withLock {
            if let url { urls.append(url) }
            remaining -= 1
            return remaining == 0 && !urls.isEmpty ? urls : nil
        }
    }
}

private struct DropZoneButtonStyle: ButtonStyle {
    var isTargeted: Bool
    var radius: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 5]))
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
    }
}
