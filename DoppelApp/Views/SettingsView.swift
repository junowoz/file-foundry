import DoppelCore
import SwiftUI

struct SettingsView: View {
    let mediaStore: AppStore
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var updateViewModel = AppUpdateViewModel()
    @State private var showUpdater = false

    var body: some View {
        Form {
            Section("Duplicate Finder") {
            LabeledContent("Exact verification") {
                Label("Byte-for-byte", systemImage: "checkmark.shield")
                    .foregroundStyle(.blue)
            }
            Toggle("Include macOS packages", isOn: $viewModel.settings.includePackages)
            Button("Check for Updates") {
                showUpdater = true
            }
            Button("Save") {
                try? viewModel.save()
            }
            }
            Section("Media Organizer") {
                LabeledContent("Sources", value: "\(mediaStore.sources.count)")
                LabeledContent("Workflow", value: mediaStore.step.title)
                Toggle("Use file dates as a last resort", isOn: Bindable(mediaStore).filesystemFallback)
                Text("Organizes copies into a verified media library without changing originals.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
        .sheet(isPresented: $showUpdater) {
            AppUpdateSheetView(viewModel: updateViewModel)
        }
    }
}
