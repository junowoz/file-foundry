import AppKit
import FileFoundryCore
import SwiftUI

struct AppUpdateSheetView: View {
    @ObservedObject var viewModel: AppUpdateViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppUpdateViewModel.autoCheckDefaultsKey) private var autoCheckForUpdates = true
    @State private var didStartInitialCheck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: statusIcon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("Check for updates automatically", isOn: $autoCheckForUpdates)
                .toggleStyle(.checkbox)

            HStack {
                Button("Open Releases") {
                    NSWorkspace.shared.open(AppMetadata.releasesURL)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .disabled(viewModel.isBusy)

                primaryButton
            }
        }
        .padding(24)
        .frame(width: 460)
        .task {
            guard !didStartInitialCheck else { return }
            didStartInitialCheck = true
            // An update found by the background check is already shown; only check when there is nothing to show.
            guard viewModel.availableRelease == nil, !viewModel.isBusy else { return }
            await viewModel.checkForUpdates()
        }
        .onDisappear {
            if !viewModel.isBusy {
                viewModel.cleanupStagedUpdate()
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch viewModel.status {
        case .idle, .upToDate, .failed:
            Button("Check Again") {
                Task { await viewModel.checkForUpdates() }
            }
            .keyboardShortcut(.defaultAction)
        case .updateAvailable:
            Button("Download and Install") {
                Task { await downloadAndInstall() }
            }
            .keyboardShortcut(.defaultAction)
        case .readyToInstall(let stagedUpdate):
            Button("Restart and Install") {
                Task { await install(stagedUpdate) }
            }
            .keyboardShortcut(.defaultAction)
        case .checking, .downloading, .installing:
            Button("Working") {}
                .disabled(true)
        }
    }

    private var title: String {
        switch viewModel.status {
        case .idle:
            "Check for Updates"
        case .checking:
            "Checking for Updates"
        case .upToDate:
            "File Foundry Is Up to Date"
        case .updateAvailable(let release):
            "File Foundry \(release.version) Is Available"
        case .downloading(let release):
            "Downloading File Foundry \(release.version)"
        case .readyToInstall(let stagedUpdate):
            "Ready to Install File Foundry \(stagedUpdate.release.version)"
        case .installing:
            "Installing Update"
        case .failed:
            "Update Failed"
        }
    }

    private var message: String {
        switch viewModel.status {
        case .idle:
            "File Foundry can check the official GitHub Releases feed and install a verified update."
        case .checking:
            "Contacting GitHub Releases with an ephemeral network session."
        case .upToDate(let version):
            "You are running File Foundry \(version)."
        case .updateAvailable:
            "The download is checked against its published SHA-256 before File Foundry restarts and replaces itself."
        case .downloading:
            "Downloading the installer and checking it against its published SHA-256."
        case .readyToInstall:
            "File Foundry will quit, replace the current app bundle, remove temporary files, and reopen."
        case .installing:
            "File Foundry will close in a moment and reopen after the update finishes."
        case .failed(let message):
            message
        }
    }

    private var statusIcon: String {
        switch viewModel.status {
        case .idle, .checking, .downloading, .installing:
            "arrow.down.circle"
        case .upToDate:
            "checkmark.seal"
        case .updateAvailable, .readyToInstall:
            "sparkles"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch viewModel.status {
        case .failed:
            .orange
        case .upToDate:
            .green
        default:
            .accentColor
        }
    }

    private var showsProgress: Bool {
        switch viewModel.status {
        case .checking, .downloading, .installing:
            true
        case .idle, .upToDate, .updateAvailable, .readyToInstall, .failed:
            false
        }
    }

    private func downloadAndInstall() async {
        guard let stagedUpdate = await viewModel.downloadAvailableUpdate() else { return }
        await install(stagedUpdate)
    }

    private func install(_ stagedUpdate: StagedAppUpdate) async {
        viewModel.markInstalling(stagedUpdate)
        do {
            try await AppUpdateInstaller.launch(stagedUpdate: stagedUpdate)
            AppUpdateInstaller.quitForUpdate()
        } catch {
            viewModel.fail(error)
        }
    }
}
