import Foundation

/// Finds command-line tools (ffmpeg, ffprobe) without involving a shell.
/// The copies shipped in `FileFoundry.app/Contents/Helpers` always win, so nothing has to be installed on the Mac;
/// Homebrew and `PATH` are only a fallback for development builds run outside the app bundle.
enum ToolLocator {
    static let knownDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// `Contents/Helpers` of the running app, where the release build puts ffmpeg and ffprobe.
    static var bundledDirectory: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) }

    static func locate(
        _ name: String,
        bundled: URL? = bundledDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let bundled {
            let url = bundled.appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        let known = knownDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        if let match = known.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) { return match }
        for path in (environment["PATH"] ?? "").split(separator: ":") {
            let url = URL(fileURLWithPath: String(path)).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// True when the app is using its own FFmpeg rather than one found on the Mac.
    static var usesBundledFFmpeg: Bool {
        locate("ffmpeg")?.deletingLastPathComponent().standardizedFileURL == bundledDirectory.standardizedFileURL
    }
}
