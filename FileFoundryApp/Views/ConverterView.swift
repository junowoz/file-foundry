import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ConverterModel {
    enum Phase: Equatable { case empty, probing, ready, running, done(CompressionResult), failed(String) }

    var phase: Phase = .empty
    var input: URL?
    var info = MediaInfo.other
    var originalBytes = 0
    var preset = ConverterPreset.videoH264
    var customOutput: URL?
    var progress: Double?
    var elapsed: TimeInterval = 0
    private var startedAt = Date()
    private var task: Task<Void, Never>?
    private var handle = ProcessHandle()

    var outputURL: URL? {
        guard let input else { return nil }
        if let customOutput, customOutput.pathExtension.lowercased() == preset.fileExtension { return customOutput }
        return OutputNaming.uniqueURL(
            directory: input.deletingLastPathComponent(), baseName: input.deletingPathExtension().lastPathComponent,
            suffix: "converted", ext: preset.fileExtension)
    }

    var commandPreview: String {
        guard let input, let output = outputURL else { return "" }
        let ffmpeg = ToolLocator.locate("ffmpeg")?.path ?? "ffmpeg"
        return ([ffmpeg] + arguments(input: input, output: output)).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    private func arguments(input: URL, output: URL) -> [String] {
        FFmpegRunner.baseArguments + ["-n", "-i", input.path] + preset.arguments + [output.path]
    }

    var details: [FileCardDetail] {
        var rows: [FileCardDetail] = []
        if info.duration > 0 { rows.append(.init(label: "Duration", value: ByteFormat.duration(info.duration))) }
        if let w = info.width, let h = info.height { rows.append(.init(label: "Resolution", value: "\(w) × \(h)")) }
        let codecs = [info.videoCodec, info.audioCodec].compactMap { $0 }.joined(separator: " + ")
        if !codecs.isEmpty { rows.append(.init(label: "Codecs", value: codecs)) }
        return rows
    }

    func load(_ url: URL) {
        let url = url.standardizedFileURL
        reset()
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else {
            phase = .failed("Choose a media file, not a folder."); return
        }
        input = url
        phase = .probing
        Task { [weak self] in
            async let size = CompressorModel.measure(url)
            async let probed = MediaProbe.probe(url)
            let (bytes, media) = await (size, probed)
            guard let self, self.input == url else { return }
            originalBytes = bytes
            info = media
            switch media.kind {
            case .audio: preset = .audioMP3
            case .image: preset = .imageJPEG
            default: preset = .videoH264
            }
            phase = .ready
        }
    }

    func reset() {
        task?.cancel(); handle.cancel()
        phase = .empty; input = nil; info = .other; originalBytes = 0; customOutput = nil; progress = nil; elapsed = 0
    }

    func chooseOutput() {
        guard let input else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = input.deletingLastPathComponent()
        panel.nameFieldStringValue = outputURL?.lastPathComponent ?? preset.defaultFilename
        if panel.runModal() == .OK, let url = panel.url {
            customOutput = url.pathExtension.lowercased() == preset.fileExtension ? url : url.appendingPathExtension(preset.fileExtension)
        }
    }

    func start() {
        guard let input, let output = outputURL else { return }
        let args = arguments(input: input, output: output)
        let duration = info.duration > 0 ? info.duration : nil
        handle = ProcessHandle()
        let handle = self.handle
        progress = duration == nil ? nil : 0; elapsed = 0; startedAt = Date()
        phase = .running
        task = Task { [weak self] in
            do {
                try OutputSafety.validate(input: input, output: output)
                try await FFmpegRunner.run(arguments: args, duration: duration, handle: handle) { f in
                    Task { @MainActor in self?.apply(f) }
                }
                self?.phase = .done(CompressionResult(
                    outputURL: output, originalBytes: self?.originalBytes ?? 0, newBytes: CompressorService.fileSize(output), targetBytes: nil))
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: output)
                self?.phase = .ready
            } catch {
                try? FileManager.default.removeItem(at: output)
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ fraction: Double) {
        guard phase == .running else { return }
        progress = fraction
        elapsed = Date().timeIntervalSince(startedAt)
    }

    func cancel() { handle.cancel(); task?.cancel() }
}

struct ConverterView: View {
    @State private var model = ConverterModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            content.frame(maxWidth: 920).padding(24).frame(maxWidth: .infinity)
        }
        .navigationTitle("Converter")
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1), value: key)
        .onDisappear { model.cancel() }
    }

    private var key: String {
        switch model.phase {
        case .empty: "empty"; case .probing: "probing"; case .ready: "ready"
        case .running: "running"; case .done: "done"; case .failed: "failed"
        }
    }
    private var enter: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)) }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Converter").font(.largeTitle.weight(.semibold))
            Text("Convert video, audio and images to another format. Everything runs on this Mac.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .empty:
            VStack(alignment: .leading, spacing: 16) {
                header
                DropZone(title: "Drop a file to convert", subtitle: "Video, audio or image · or click to choose", allowsDirectories: false) { model.load($0) }
                if ToolLocator.locate("ffmpeg") == nil { InlineMessage(text: ToolError.toolMissing("FFmpeg").localizedDescription) }
            }.transition(enter)
        case .probing, .ready:
            VStack(alignment: .leading, spacing: 16) {
                header
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        fileCard.frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                        options.frame(minWidth: 360, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 16) { fileCard; options }
                }
            }.transition(enter)
        case .running:
            VStack(alignment: .leading, spacing: 16) {
                fileCard
                ProgressPanel(label: "Converting to \(model.preset.fileExtension.uppercased())", fraction: model.progress, elapsed: model.elapsed) { model.cancel() }
            }.frame(maxWidth: 560).transition(enter)
        case .done(let result):
            ResultPanel(outputURL: result.outputURL, originalBytes: result.originalBytes, newBytes: result.newBytes,
                        percentSmaller: nil, warning: nil, againTitle: "Convert another") { model.reset() }
                .frame(maxWidth: 480).transition(enter)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                InlineMessage(text: message)
                Button("Choose another file") { model.reset() }
            }.frame(maxWidth: 560).transition(enter)
        }
    }

    @ViewBuilder private var fileCard: some View {
        if let input = model.input {
            FileCard(url: input, kind: model.info.kind == .other ? "File" : "\(model.info.kind.rawValue.capitalized)",
                     size: ByteFormat.string(model.originalBytes), details: model.details, isLoading: model.phase == .probing) { model.reset() }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.phase == .ready {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Convert to", selection: $model.preset) {
                        ForEach(ConverterPreset.Group.allCases, id: \.self) { group in
                            Section(group.rawValue) {
                                ForEach(ConverterPreset.allCases.filter { $0.group == group }) { Text($0.shortTitle).tag($0) }
                            }
                        }
                    }
                    Text(".\(model.preset.fileExtension) · \(model.preset.detail)").font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("Show FFmpeg command") {
                        Text(model.commandPreview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }.font(.callout)
                }.foundryCard()
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(model.outputURL?.path ?? "").lineLimit(1).truncationMode(.middle).font(.callout)
                    Spacer()
                    Button("Change…") { model.chooseOutput() }.controlSize(.small)
                }.foundryCard()
                HStack {
                    Spacer()
                    Button("Convert") { model.start() }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else {
                Text("Reading file…").foregroundStyle(.secondary)
            }
        }
    }
}

enum ConverterPreset: String, CaseIterable, Identifiable {
    case videoH264, videoHEVC, videoWebM, audioMP3, audioAAC, audioWAV, audioFLAC, imageJPEG, imagePNG
    enum Group: String, CaseIterable { case video = "Video", audio = "Audio", image = "Image" }
    var id: String { rawValue }
    var group: Group { switch self { case .videoH264, .videoHEVC, .videoWebM: .video; case .audioMP3, .audioAAC, .audioWAV, .audioFLAC: .audio; case .imageJPEG, .imagePNG: .image } }
    var shortTitle: String { switch self { case .videoH264: "H.264 MP4"; case .videoHEVC: "HEVC MP4"; case .videoWebM: "VP9 WebM"; case .audioMP3: "MP3"; case .audioAAC: "AAC M4A"; case .audioWAV: "WAV"; case .audioFLAC: "FLAC"; case .imageJPEG: "JPEG"; case .imagePNG: "PNG" } }
    var title: String { "\(group.rawValue) — \(shortTitle)" }
    var detail: String { "FFmpeg local conversion preset for .\(fileExtension) output." }
    var fileExtension: String { switch self { case .videoH264, .videoHEVC: "mp4"; case .videoWebM: "webm"; case .audioMP3: "mp3"; case .audioAAC: "m4a"; case .audioWAV: "wav"; case .audioFLAC: "flac"; case .imageJPEG: "jpg"; case .imagePNG: "png" } }
    var defaultFilename: String { "converted.\(fileExtension)" }
    var arguments: [String] { switch self { case .videoH264: ["-c:v", "libx264", "-crf", "20", "-c:a", "aac"]; case .videoHEVC: ["-c:v", "libx265", "-crf", "24", "-c:a", "aac"]; case .videoWebM: ["-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-c:a", "libopus"]; case .audioMP3: ["-vn", "-c:a", "libmp3lame", "-b:a", "320k"]; case .audioAAC: ["-vn", "-c:a", "aac", "-b:a", "256k"]; case .audioWAV: ["-vn", "-c:a", "pcm_s16le"]; case .audioFLAC: ["-vn", "-c:a", "flac"]; case .imageJPEG: ["-frames:v", "1", "-q:v", "2"]; case .imagePNG: ["-frames:v", "1", "-compression_level", "6"] } }
}

enum ConverterExecutable {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> URL? {
        ToolLocator.locate("ffmpeg", environment: environment, fileManager: fileManager)
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
