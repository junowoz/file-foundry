import AppKit
import SwiftUI

// Shared building blocks so every rack has the same structure, spacing and behavior.
// Layout of a rack: optional left pane (RackLayout widths) | main content | RackStatusBar at the bottom.
// Empty screens use RackEmptyState. File pickers use NSOpenPanel.presentAsSheet, never runModal.

enum RackLayout {
    /// Spacing scale (points). Use only these values for padding and gaps.
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    /// Left pane of a rack (list, sources, settings column).
    static let paneMin: CGFloat = 240
    static let paneIdeal: CGFloat = 280
    static let paneMax: CGFloat = 340
    /// Main content never gets narrower than this.
    static let contentMin: CGFloat = 380
    /// Readable column width for forms and centered content.
    static let readableWidth: CGFloat = 640

    static let cornerRadius: CGFloat = 12
}

/// Centered empty state with one primary action and an optional secondary one.
struct RackEmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var primaryTitle: String?
    var primarySymbol = "plus"
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondarySymbol: String?
    var secondaryAction: (() -> Void)?
    /// Small print under the actions (formats, privacy note). Keep it to one or two short lines.
    var footnote: String?

    var body: some View {
        VStack(spacing: RackLayout.xl) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: RackLayout.s) {
                Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)
            if primaryAction != nil || secondaryAction != nil {
                HStack(spacing: RackLayout.m) {
                    if let primaryTitle, let primaryAction {
                        Button(action: primaryAction) { Label(primaryTitle, systemImage: primarySymbol) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                    if let secondaryTitle, let secondaryAction {
                        Button(action: secondaryAction) {
                            if let secondarySymbol { Label(secondaryTitle, systemImage: secondarySymbol) } else { Text(secondaryTitle) }
                        }
                    }
                }
                .controlSize(.large)
            }
            if let footnote {
                Text(footnote).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(RackLayout.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bottom bar of a rack: status text on the leading side, small stats or actions on the trailing side.
struct RackStatusBar<Trailing: View>: View {
    var status: String
    var symbol: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: RackLayout.l) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true) }
            Text(status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: RackLayout.s)
            trailing()
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, RackLayout.l)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension RackStatusBar where Trailing == EmptyView {
    init(status: String, symbol: String? = nil) {
        self.init(status: status, symbol: symbol) { EmptyView() }
    }
}

/// Section title used inside panes and forms.
struct RackSectionHeader: View {
    var title: String
    var body: some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension NSSavePanel {
    /// Shows the panel attached to the current window, so the rest of the app keeps working.
    /// Works for NSOpenPanel too. Falls back to a modal panel only when there is no window.
    @MainActor
    func presentAsSheet(_ completion: @escaping (Bool) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, attachedSheet(of: window) == nil {
            beginSheetModal(for: window) { completion($0 == .OK) }
        } else {
            completion(runModal() == .OK)
        }
    }

    private func attachedSheet(of window: NSWindow) -> NSWindow? { window.attachedSheet }
}
