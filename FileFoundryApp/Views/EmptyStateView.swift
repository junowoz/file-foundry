import SwiftUI

/// Standard empty state (ContentUnavailableView) with an optional call to action.
struct EmptyStateView: View {
    var title: String
    var message: String
    var symbol: String = "doc.on.doc"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, systemImage: "plus", action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
