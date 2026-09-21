import SwiftUI

struct ConfigureView: View {
    let store: AppStore
    private let presets = [
        ("Somente Ano", "{YYYY}"),
        ("Ano + Mês — recomendado", TemplateEngine.defaultTemplate),
        ("Ano + Mês numérico", "{YYYY}/{MM}"),
        ("Tipo + Ano + Mês", "{MediaType}/{YYYY}/{MM} - {Month}")
    ]

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Estrutura").font(.title2).fontWeight(.semibold)
                ForEach(presets, id: \.1) { preset in
                    Button {
                        store.template = preset.1; store.refreshPlan()
                    } label: {
                        HStack {
                            Image(systemName: store.template == preset.1 ? "largecircle.fill.circle" : "circle")
                            VStack(alignment: .leading) { Text(preset.0); Text(preset.1).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                        }
                    }.buttonStyle(.plain).padding(8)
                }
                Text("Template customizado").font(.headline)
                TextField("{YYYY}/{MM} - {Month}", text: Bindable(store).template)
                    .onSubmit { store.refreshPlan() }
                Button("Aplicar template") { store.refreshPlan() }
                Divider()
                Toggle("Usar data do arquivo como último recurso", isOn: Bindable(store).filesystemFallback)
                Text("Desligado por padrão: datas do Finder podem representar uma cópia ou download.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding().frame(minWidth: 330, idealWidth: 380)

            VStack(alignment: .leading, spacing: 14) {
                Text("Destino e resumo").font(.title2).fontWeight(.semibold)
                HStack {
                    VStack(alignment: .leading) {
                        Text(store.destinationParent?.url.lastPathComponent ?? "Nenhum destino escolhido")
                        Text(store.destinationParent?.url.path ?? "Uma nova pasta exclusiva será criada aqui.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(); Button("Escolher destino…") { store.chooseDestination() }
                }
                Divider()
                if let summary = store.summary {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], spacing: 12) {
                        MetricCard(title: "Total", value: summary.records.count)
                        MetricCard(title: "Fotos", value: summary.exportableRecords.filter { $0.kind == .photo }.count)
                        MetricCard(title: "Vídeos", value: summary.exportableRecords.filter { $0.kind == .video }.count)
                        MetricCard(title: "Áudios", value: summary.exportableRecords.filter { $0.kind == .audio }.count)
                        MetricCard(title: "Duplicados", value: summary.duplicateGroups.reduce(0) { $0 + $1.duplicateIDs.count })
                        MetricCard(title: "Sem data", value: summary.undatedCount)
                        MetricCard(title: "Erros de acesso", value: summary.enumerationErrorCount)
                    }
                    if !summary.isComplete {
                        Toggle("Entendo que a exportação ficará incompleta", isOn: Bindable(store).acceptsIncompleteScan)
                            .foregroundStyle(.orange)
                        Text("Os caminhos inacessíveis serão mantidos na origem e registrados; nada será apagado.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Preview").font(.headline)
                List(store.plan?.items.prefix(80).map { $0 } ?? []) { item in
                    Label(item.destinationRelativePath, systemImage: icon(item.status)).lineLimit(1)
                }
                HStack {
                    Label("Somente cópia • SHA-256 • Sem sobrescrita • 100% local", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revisar plano") { store.review() }.buttonStyle(.borderedProminent).disabled(store.destinationParent == nil || store.plan == nil)
                }
            }
            .padding().frame(minWidth: 520)
        }
    }

    private func icon(_ status: PlannedStatus) -> String {
        switch status { case .exactDuplicate: "doc.on.doc"; case .undated: "questionmark.folder"; case .renamedCollision: "arrow.triangle.branch"; default: "doc" }
    }
}

private struct MetricCard: View {
    let title: String; let value: Int
    var body: some View { VStack(alignment: .leading) { Text(value.formatted()).font(.title2).fontWeight(.semibold); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10)) }
}
