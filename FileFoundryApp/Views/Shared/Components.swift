import SwiftUI

extension View {
    /// Grouped surface used across the tool screens.
    func foundryCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
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
