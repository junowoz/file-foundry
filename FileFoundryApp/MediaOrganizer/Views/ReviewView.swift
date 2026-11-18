import SwiftUI

struct ReviewView: View {
    let store: AppStore
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: RackLayout.m) {
                HStack {
                    Text("Review Before Copying").font(.title).fontWeight(.semibold)
                    Spacer()
                    Text("\(filtered.count) items").foregroundStyle(.secondary).monospacedDigit()
                }
                Table(filtered) {
                    TableColumn("Name") { Text($0.record.filename).lineLimit(1) }
                    TableColumn("Type") { Text($0.record.kind.rawValue) }.width(80)
                    TableColumn("Date Used") { Text(dateText($0.record.captureMoment)) }.width(110)
                    TableColumn("Source") { Text($0.record.relativePath).lineLimit(1) }
                    TableColumn("Destination") { Text($0.destinationRelativePath).lineLimit(1) }
                    TableColumn("Status") { Text(statusText($0.status)) }.width(130)
                }
                .searchable(text: $query, prompt: "Search files")
            }
            .padding(RackLayout.l)
            RackStatusBar(status: "Nothing has been written to the destination yet.", symbol: "eye") {
                HStack(spacing: RackLayout.s) {
                    Button("Back") { store.step = .configure }
                    Button("Create Organized Copy") { store.export() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var filtered: [PlannedItem] {
        let items = store.plan?.items ?? []
        return query.isEmpty ? items : items.filter { $0.record.filename.localizedCaseInsensitiveContains(query) || $0.destinationRelativePath.localizedCaseInsensitiveContains(query) }
    }
    private func dateText(_ moment: CaptureMoment?) -> String { guard let moment else { return "No date" }; return String(format: "%04d-%02d-%02d", moment.year ?? 0, moment.month ?? 0, moment.day ?? 0) }
    private func statusText(_ status: PlannedStatus) -> String { switch status { case .copy: "Will be copied"; case .exactDuplicate: "Exact duplicate"; case .undated: "No date"; case .renamedCollision: "Renamed to avoid collision"; case .sidecar: "Sidecar"; case .other: "Other" } }
}
