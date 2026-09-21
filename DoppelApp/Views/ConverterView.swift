import AppKit
import SwiftUI

struct ConverterView: View {
    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @State private var preset = ConverterPreset.videoH264
    @State private var isRunning = false
    @State private var status = "Ready"
    @State private var process: Process?
    @State private var cancellationRequested = false

    var body: some View {
        Form {
            Section("Input and output") {
                HStack { Text(inputURL?.path ?? "No input selected").lineLimit(1).truncationMode(.middle); Spacer(); Button("Choose…", action: chooseInput) }
                HStack { Text(outputURL?.path ?? "Output will be chosen when you convert").lineLimit(1).truncationMode(.middle); Spacer(); Button("Save as…", action: chooseOutput) }
            }
            Section("Preset") { Picker("Conversion", selection: $preset) { ForEach(ConverterPreset.allCases) { Text($0.title).tag($0) } }; Text(preset.detail).font(.caption).foregroundStyle(.secondary) }
            Section("Command preview") { Text(commandPreview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Button("Convert", action: convert).disabled(inputURL == nil || isRunning); if isRunning { Button("Cancel", role: .cancel, action: cancel) }; Spacer(); Text(status).foregroundStyle(.secondary) }
        }.formStyle(.grouped).padding().navigationTitle("Converter").onDisappear { cancel() }
    }

    private var commandPreview: String { "ffmpeg -n -i \(inputURL?.path ?? "input") \(preset.arguments.joined(separator: " ")) \(outputURL?.path ?? preset.defaultFilename)" }
    private func chooseInput() { let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; guard p.runModal() == .OK else { return }; inputURL = p.url; outputURL = nil; status = "Ready" }
    private func chooseOutput() { let p = NSSavePanel(); p.canCreateDirectories = true; p.nameFieldStringValue = preset.defaultFilename; guard p.runModal() == .OK else { return }; outputURL = p.url }

    private func convert() {
        guard let inputURL, !inputURL.pathExtension.isEmpty else { status = "Choose a valid input file"; return }
        if outputURL == nil { chooseOutput() }
        guard let outputURL else { return }
        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL else { status = "Input and output must be different files"; return }
        guard outputURL.pathExtension.lowercased() == preset.fileExtension else { status = "Output must use .\(preset.fileExtension)"; return }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else { status = "Output exists; choose a new path"; return }
        guard let executable = ConverterExecutable.locate() else { status = "FFmpeg was not found"; return }
        let task = Process(); task.executableURL = executable; task.arguments = ["-n", "-i", inputURL.path] + preset.arguments + [outputURL.path]
        let pipe = Pipe(); task.standardError = pipe; process = task; cancellationRequested = false; isRunning = true; status = "Converting…"
        DispatchQueue.global(qos: .utility).async { _ = pipe.fileHandleForReading.readDataToEndOfFile() }
        task.terminationHandler = { [weak task] _ in DispatchQueue.main.async { let cancelled = cancellationRequested; isRunning = false; process = nil; status = cancelled ? "Conversion cancelled" : (task?.terminationStatus == 0 ? "Conversion complete" : "Conversion failed") } }
        do { try task.run() } catch { isRunning = false; process = nil; status = error.localizedDescription }
    }
    private func cancel() { cancellationRequested = true; process?.terminate(); process = nil; if isRunning { isRunning = false; status = "Conversion cancelled" } }
}

enum ConverterPreset: String, CaseIterable, Identifiable {
    case videoH264, videoHEVC, videoWebM, audioMP3, audioAAC, audioWAV, audioFLAC, imageJPEG, imagePNG
    var id: String { rawValue }
    var title: String { switch self { case .videoH264: "Video — H.264 MP4"; case .videoHEVC: "Video — HEVC MP4"; case .videoWebM: "Video — VP9 WebM"; case .audioMP3: "Audio — MP3"; case .audioAAC: "Audio — AAC M4A"; case .audioWAV: "Audio — WAV"; case .audioFLAC: "Audio — FLAC"; case .imageJPEG: "Image — JPEG"; case .imagePNG: "Image — PNG" } }
    var detail: String { "FFmpeg local conversion preset for .\(fileExtension) output." }
    var fileExtension: String { switch self { case .videoH264, .videoHEVC: "mp4"; case .videoWebM: "webm"; case .audioMP3: "mp3"; case .audioAAC: "m4a"; case .audioWAV: "wav"; case .audioFLAC: "flac"; case .imageJPEG: "jpg"; case .imagePNG: "png" } }
    var defaultFilename: String { "converted.\(fileExtension)" }
    var arguments: [String] { switch self { case .videoH264: ["-c:v", "libx264", "-crf", "20", "-c:a", "aac"]; case .videoHEVC: ["-c:v", "libx265", "-crf", "24", "-c:a", "aac"]; case .videoWebM: ["-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-c:a", "libopus"]; case .audioMP3: ["-vn", "-c:a", "libmp3lame", "-b:a", "320k"]; case .audioAAC: ["-vn", "-c:a", "aac", "-b:a", "256k"]; case .audioWAV: ["-vn", "-c:a", "pcm_s16le"]; case .audioFLAC: ["-vn", "-c:a", "flac"]; case .imageJPEG: ["-frames:v", "1", "-q:v", "2"]; case .imagePNG: ["-frames:v", "1", "-compression_level", "6"] } }
}

enum ConverterExecutable {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> URL? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        if let match = candidates.map({ URL(fileURLWithPath: $0) }).first(where: { fileManager.isExecutableFile(atPath: $0.path) }) { return match }
        for path in (environment["PATH"] ?? "").split(separator: ":") { let url = URL(fileURLWithPath: String(path)).appendingPathComponent("ffmpeg"); if fileManager.isExecutableFile(atPath: url.path) { return url } }
        return nil
    }

    static func probe() -> Bool {
        guard let executable = locate() else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
