import AppKit
import Darwin
import FileFoundryCore
import SwiftUI

@main
struct FileFoundryApp: App {
    @State private var mediaStore = AppStore()
    init() {
        if ProcessInfo.processInfo.environment["FILE_FOUNDRY_VERIFY_FFMPEG"] == "1" {
            let available = ConverterExecutable.probe()
            let path = ConverterExecutable.locate()?.path ?? "none"
            let message = available ? "FFmpeg probe passed: \(path)\n" : "FFmpeg probe failed: \(path)\n"
            FileHandle.standardOutput.write(Data(message.utf8))
            exit(available ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        try? AppUpdateService().cleanupTemporaryFiles()
    }

    var body: some Scene {
        WindowGroup {
            FileFoundryRootView(mediaStore: mediaStore)
                .frame(minWidth: 760, minHeight: 520)
        }

        Settings {
            SettingsView(mediaStore: mediaStore)
        }
        .commands {
            TranscribeCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .fileFoundryShowUpdater, object: nil)
                }
            }
            CommandGroup(replacing: .help) {
                Button("File Foundry Help") {
                    NSWorkspace.shared.open(AppMetadata.repositoryURL)
                }
            }
        }
    }
}
