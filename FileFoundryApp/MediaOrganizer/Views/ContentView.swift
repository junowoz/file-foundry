import SwiftUI

struct ContentView: View {
    let store: AppStore
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            WorkflowHeader(step: store.step)
            Divider()
            Group {
                switch store.step {
                case .sources: SourcesView(store: store)
                case .configure: ConfigureView(store: store)
                case .review: ReviewView(store: store)
                case .copy: CopyProgressView(store: store)
                case .report: ReportView(store: store)
                }
            }
            if let error = store.errorMessage {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .accessibilityLabel("Erro: \(error)")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Label("Somente cópia", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Media Organizer Settings", systemImage: "gearshape") { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) { MediaOrganizerSettingsView(store: store) }
    }
}

private struct WorkflowHeader: View {
    let step: WorkflowStep
    var body: some View {
        HStack(spacing: 10) {
            ForEach(WorkflowStep.allCases) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.rawValue < step.rawValue ? "checkmark.circle.fill" : "\(item.rawValue + 1).circle.fill")
                        .foregroundStyle(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary)
                    Text(item.title).fontWeight(item == step ? .semibold : .regular)
                }
                if item != .report { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
            Spacer()
            Text("Originais protegidos").font(.caption).padding(.horizontal, 10).padding(.vertical, 5).background(.green.opacity(0.12), in: Capsule())
        }
        .padding()
    }
}
