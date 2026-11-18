import SwiftUI

struct ConfigureView: View {
    let store: AppStore
    private let presets = [
        ("Year Only", "{YYYY}"),
        ("Year + Month (Recommended)", TemplateEngine.defaultTemplate),
        ("Year + Numeric Month", "{YYYY}/{MM}"),
        ("Media Type + Year + Month", "{MediaType}/{YYYY}/{MM} - {Month}")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView { structurePane.frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(minWidth: RackLayout.paneMin, idealWidth: RackLayout.paneIdeal, maxWidth: RackLayout.paneMax)
                    Divider()
                    destinationPane.frame(minWidth: 400)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: RackLayout.xl) {
                        structurePane
                        Divider()
                        destinationPane.frame(minHeight: 360)
                    }
                }
            }
            RackStatusBar(status: store.statusMessage) {
                Button("Review Plan") { store.review() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.destinationParent == nil || store.plan == nil)
            }
        }
    }

    private var structurePane: some View {
        VStack(alignment: .leading, spacing: RackLayout.m) {
            Text("Structure").font(.title2).fontWeight(.semibold)
            VStack(spacing: RackLayout.xs) {
                ForEach(presets, id: \.1) { preset in
                    Button {
                        store.template = preset.1; store.refreshPlan()
                    } label: {
                        HStack {
                            Image(systemName: store.template == preset.1 ? "largecircle.fill.circle" : "circle")
                            VStack(alignment: .leading) { Text(preset.0); Text(preset.1).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                        }
                    }.buttonStyle(.plain).padding(RackLayout.s)
                }
            }
            .foundryCard()
            Text("Custom template").font(.headline)
            TextField("{YYYY}/{MM} - {Month}", text: Bindable(store).template)
                .onSubmit { store.refreshPlan() }
            Button("Apply Template") { store.refreshPlan() }
            Divider()
            Toggle("Use file date as a last resort", isOn: Bindable(store).filesystemFallback)
            Text("Off by default. Finder dates can reflect a copy or download.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(RackLayout.l)
    }

    private var destinationPane: some View {
        VStack(alignment: .leading, spacing: RackLayout.m) {
            Text("Destination and Summary").font(.title2).fontWeight(.semibold)
            HStack {
                VStack(alignment: .leading) {
                    Text(store.destinationParent?.url.lastPathComponent ?? "No destination chosen")
                    Text(store.destinationParent?.url.path ?? "A new, separate folder will be created here.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(); Button("Choose Destination…") { store.chooseDestination() }
            }
            Divider()
            if let summary = store.summary {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: RackLayout.s)], spacing: RackLayout.s) {
                    MetricCard(title: "Total", value: summary.records.count)
                    MetricCard(title: "Photos", value: summary.exportableRecords.filter { $0.kind == .photo }.count)
                    MetricCard(title: "Videos", value: summary.exportableRecords.filter { $0.kind == .video }.count)
                    MetricCard(title: "Audio", value: summary.exportableRecords.filter { $0.kind == .audio }.count)
                    MetricCard(title: "Duplicates", value: summary.duplicateGroups.reduce(0) { $0 + $1.duplicateIDs.count })
                    MetricCard(title: "Undated", value: summary.undatedCount)
                    MetricCard(title: "Access Errors", value: summary.enumerationErrorCount)
                }
                if !summary.isComplete {
                    Toggle("I understand the export will be incomplete", isOn: Bindable(store).acceptsIncompleteScan)
                        .foregroundStyle(.orange)
                    Text("Paths you can't access stay in the source and are logged. Nothing is deleted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Preview").font(.headline)
            List(store.plan?.items.prefix(80).map { $0 } ?? []) { item in
                Label(item.destinationRelativePath, systemImage: icon(item.status)).lineLimit(1).truncationMode(.middle)
            }
            .frame(minHeight: 120)
            Label("Copy only • Checksum verified • No overwrites • 100% local", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(RackLayout.l)
    }

    private func icon(_ status: PlannedStatus) -> String {
        switch status { case .exactDuplicate: "doc.on.doc"; case .undated: "questionmark.folder"; case .renamedCollision: "arrow.triangle.branch"; default: "doc" }
    }
}

private struct MetricCard: View {
    let title: String; let value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: RackLayout.xs) {
            Text(value.formatted()).font(.title2).fontWeight(.semibold).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RackLayout.s)
        .foundryCard()
    }
}
