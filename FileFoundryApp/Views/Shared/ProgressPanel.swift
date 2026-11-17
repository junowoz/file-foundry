import SwiftUI

/// Determinate progress with elapsed and ETA. Values are pushed by the model (no timers).
struct ProgressPanel: View {
    var label: String
    var fraction: Double?
    var elapsed: TimeInterval
    var onCancel: () -> Void

    private var eta: TimeInterval? {
        guard let fraction, fraction > 0.03, fraction < 1 else { return nil }
        return elapsed * (1 - fraction) / fraction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(label).font(.headline).contentTransition(.opacity)
                Spacer()
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.headline).monospacedDigit().contentTransition(.numericText(value: fraction))
                }
            }
            if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
            HStack {
                Text("Elapsed \(ByteFormat.duration(elapsed))")
                Spacer()
                if let eta { Text("About \(ByteFormat.duration(eta)) left") }
            }
            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .foundryCard()
    }
}
