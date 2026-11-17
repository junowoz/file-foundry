import SwiftUI

struct ReviewView: View {
    let store: AppStore
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Revise antes de copiar").font(.title).fontWeight(.semibold); Spacer(); Text("\(filtered.count) itens").foregroundStyle(.secondary).monospacedDigit() }
            Table(filtered) {
                TableColumn("Nome") { Text($0.record.filename).lineLimit(1) }
                TableColumn("Tipo") { Text($0.record.kind.rawValue) }.width(80)
                TableColumn("Data usada") { Text(dateText($0.record.captureMoment)) }.width(110)
                TableColumn("Origem") { Text($0.record.relativePath).lineLimit(1) }
                TableColumn("Destino") { Text($0.destinationRelativePath).lineLimit(1) }
                TableColumn("Status") { Text(statusText($0.status)) }.width(130)
            }
            .searchable(text: $query, prompt: "Buscar arquivos")
            HStack(spacing: 8) {
                Button("Voltar") { store.step = .configure }
                Spacer()
                Label("Nada foi escrito no destino até aqui.", systemImage: "eye").foregroundStyle(.secondary).font(.callout).lineLimit(1)
                Button("Criar cópia organizada") { store.export() }.buttonStyle(.borderedProminent)
            }
        }.padding(16)
    }

    private var filtered: [PlannedItem] {
        let items = store.plan?.items ?? []
        return query.isEmpty ? items : items.filter { $0.record.filename.localizedCaseInsensitiveContains(query) || $0.destinationRelativePath.localizedCaseInsensitiveContains(query) }
    }
    private func dateText(_ moment: CaptureMoment?) -> String { guard let moment else { return "Sem data" }; return String(format: "%04d-%02d-%02d", moment.year ?? 0, moment.month ?? 0, moment.day ?? 0) }
    private func statusText(_ status: PlannedStatus) -> String { switch status { case .copy: "Será copiado"; case .exactDuplicate: "Duplicado exato"; case .undated: "Sem data"; case .renamedCollision: "Colisão renomeada"; case .sidecar: "Sidecar"; case .other: "Outro" } }
}
