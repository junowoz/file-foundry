import SwiftUI

struct ReportView: View {
    let store: AppStore
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: failureCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 58)).foregroundStyle(failureCount == 0 ? .green : .orange)
            Text(failureCount == 0 ? "Cópia organizada e verificada" : "Exportação concluída com atenção")
                .font(.largeTitle).fontWeight(.semibold)
            Text(store.statusMessage).foregroundStyle(.secondary)
            HStack(spacing: 40) {
                reportMetric("Verificados", verifiedCount)
                reportMetric("Falhas", failureCount)
                reportMetric("Bytes", verifiedBytes.formatted(.byteCount(style: .file)))
            }.padding(24).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            Button("Mostrar cópia no Finder") { store.revealOutput() }.buttonStyle(.borderedProminent)
            Text("Manifest JSON, CSV e relatório Markdown estão na pasta Relatórios.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding()
    }
    private var verifiedCount: Int { store.manifest?.records.filter { $0.status == .committedVerified }.count ?? 0 }
    private var failureCount: Int { store.manifest?.records.filter { $0.status == .failed }.count ?? 0 }
    private var verifiedBytes: Int64 { store.manifest?.records.filter { $0.status == .committedVerified }.reduce(0) { $0 + $1.bytes } ?? 0 }
    private func reportMetric(_ title: String, _ value: some StringProtocol) -> some View { VStack { Text(value).font(.title2).fontWeight(.semibold); Text(title).font(.caption).foregroundStyle(.secondary) } }
    private func reportMetric(_ title: String, _ value: Int) -> some View { reportMetric(title, String(value)) }
}
