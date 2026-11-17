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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.08))
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
        HStack(spacing: 16) {
            ViewThatFits(in: .horizontal) {
                fullStepper
                compactStepper
            }
            Spacer(minLength: 8)
            Label("Originais protegidos", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.green.opacity(0.12), in: Capsule())
                .lineLimit(1)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private var fullStepper: some View {
        HStack(spacing: 8) {
            ForEach(WorkflowStep.allCases) { item in
                HStack(spacing: 8) {
                    marker(for: item)
                    Text(item.title)
                        .font(.callout)
                        .fontWeight(item == step ? .semibold : .regular)
                        .foregroundStyle(item.rawValue <= step.rawValue ? .primary : .secondary)
                        .lineLimit(1)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.title), passo \(item.rawValue + 1) de \(WorkflowStep.allCases.count)")
                .accessibilityAddTraits(item == step ? .isSelected : [])
                if item != WorkflowStep.allCases.last {
                    Capsule()
                        .fill(item.rawValue < step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 24, height: 2)
                }
            }
        }
    }

    private var compactStepper: some View {
        HStack(spacing: 8) {
            marker(for: step)
            Text(step.title).font(.callout.weight(.semibold))
            Text("\(step.rawValue + 1) de \(WorkflowStep.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ProgressView(value: Double(step.rawValue + 1), total: Double(WorkflowStep.allCases.count))
                .frame(width: 72)
        }
        .fixedSize()
    }

    private func marker(for item: WorkflowStep) -> some View {
        let done = item.rawValue < step.rawValue
        let current = item == step
        return ZStack {
            Circle().fill(done || current ? Color.accentColor : Color.secondary.opacity(0.2))
            if done {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            } else {
                Text("\(item.rawValue + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(current ? .white : .secondary)
            }
        }
        .frame(width: 20, height: 20)
    }
}
