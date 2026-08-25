import DoppelCore
import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var updateViewModel = AppUpdateViewModel()
    @State private var showUpdater = false

    var body: some View {
        Form {
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
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
        .sheet(isPresented: $showUpdater) {
            AppUpdateSheetView(viewModel: updateViewModel)
        }
    }
}
