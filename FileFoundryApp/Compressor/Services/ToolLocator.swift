import Foundation

/// Finds command-line tools (ffmpeg, ffprobe) without involving a shell.
enum ToolLocator {
    static let knownDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func locate(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let known = knownDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        if let match = known.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) { return match }
        for path in (environment["PATH"] ?? "").split(separator: ":") {
            let url = URL(fileURLWithPath: String(path)).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
