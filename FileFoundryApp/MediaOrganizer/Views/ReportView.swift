import SwiftUI

struct ReportView: View {
    let store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: RackLayout.xl) {
                    Image(systemName: failureCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 58)).foregroundStyle(failureCount == 0 ? .green : .orange)
                    Text(failureCount == 0 ? "Organized copy created and verified" : "Export finished with issues")
                        .font(.title).fontWeight(.semibold).multilineTextAlignment(.center)
                    HStack(spacing: RackLayout.xl) {
                        reportMetric("Verified", verifiedCount)
                        reportMetric("Failed", failureCount)
                        reportMetric("Size", verifiedBytes.formatted(.byteCount(style: .file)))
                    }
                    .padding(RackLayout.l)
                    .foundryCard()
                    Button("Show Copy in Finder") { store.revealOutput() }.buttonStyle(.borderedProminent)
                    Text("The JSON manifest, CSV and Markdown reports are in the Reports folder.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(RackLayout.xl)
                .frame(maxWidth: .infinity)
            }
            RackStatusBar(status: store.statusMessage)
        }
    }
    private var verifiedCount: Int { store.manifest?.records.filter { $0.status == .committedVerified }.count ?? 0 }
    private var failureCount: Int { store.manifest?.records.filter { $0.status == .failed }.count ?? 0 }
    private var verifiedBytes: Int64 { store.manifest?.records.filter { $0.status == .committedVerified }.reduce(0) { $0 + $1.bytes } ?? 0 }
    private func reportMetric(_ title: String, _ value: some StringProtocol) -> some View { VStack { Text(value).font(.title2).fontWeight(.semibold).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) } }
    private func reportMetric(_ title: String, _ value: Int) -> some View { reportMetric(title, String(value)) }
}
