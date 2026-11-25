import AppKit
import FileFoundryCore
import Foundation

enum AppUpdateInstaller {
    static func launch(stagedUpdate: StagedAppUpdate) async throws {
        let currentBundleURL = Bundle.main.bundleURL
        guard currentBundleURL.pathExtension == "app" else {
            throw AppUpdateError.unsupportedBundleLocation(currentBundleURL.path)
        }

        let helperURL = currentBundleURL
            .appendingPathComponent("Contents/Library/Helpers/FileFoundryUpdater.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw AppUpdateError.missingUpdaterHelper(helperURL.path)
        }

        // `open -n -g` returns as soon as LaunchServices has started the helper. NSWorkspace.openApplication's
        // completion handler could stay pending forever, which left the app on "Installing Update" without quitting.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n", "-g", helperURL.path, "--args",
            "--pid", "\(ProcessInfo.processInfo.processIdentifier)",
            "--source", stagedUpdate.appBundleURL.path,
            "--destination", currentBundleURL.path,
            "--cleanup", stagedUpdate.stagingDirectory.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
        guard status == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AppUpdateError.commandFailed(command: "Starting the updater", output: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Quits so the helper can replace the app. If something refuses a normal quit, force it: the helper waits
    /// for this process to exit, so the update must never depend on a polite quit.
    @MainActor
    static func quitForUpdate() {
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }
}
