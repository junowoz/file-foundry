import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CompressorModel {
    enum Phase: Equatable { case empty, probing, ready, running, done(CompressionResult), failed(String) }

    var phase: Phase = .empty
    var input: URL?
    var info = MediaInfo.other
    var originalBytes = 0

    var mode: CompressionMode = .targetSize
    var targetText = "25"
    var codec: VideoCodecChoice = .h264
    var preset: QualityPreset = .balanced
    var imageFormat: ImageFormat = .jpeg
    var imageQuality = 82.0
    var maxDimensionText = ""
    var webpAvailable = false
    var customOutput: URL?

    var progress: Double?
    var progressLabel = ""
    var elapsed: TimeInterval = 0
    private var startedAt = Date()
    private var task: Task<Void, Never>?
    private var handle = ProcessHandle()
    private var tempDir: URL?
    private let previewPassLog = FileManager.default.temporaryDirectory.appendingPathComponent("FileFoundry-pass/pass").path

    var ffmpegMissing: Bool { ToolLocator.locate("ffmpeg") == nil }

    // MARK: Derived values

    var kind: ContentKind { info.kind }
    var supportsTarget: Bool { true }

    var targetBytes: Int {
        let normalized = targetText.replacingOccurrences(of: ",", with: ".")
        guard let mb = Double(normalized), mb > 0 else { return 0 }
        return Int(mb * 1_000_000)
    }

    var maxDimension: Int? {
        guard let v = Int(maxDimensionText), v >= 16 else { return nil }
        return v
    }

    var request: CompressionRequest {
        CompressionRequest(
            info: info, originalBytes: originalBytes, mode: mode, targetBytes: targetBytes, codec: codec, preset: preset,
            image: ImageSettings(format: imageFormat, quality: Int(imageQuality), maxDimension: maxDimension))
    }

    var outputURL: URL? {
        guard let input, let plan = currentPlan(output: nil) else { return nil }
        if let customOutput, customOutput.pathExtension.lowercased() == plan.outputExtension { return customOutput }
        return OutputNaming.uniqueURL(
            directory: input.deletingLastPathComponent(),
            baseName: input.deletingPathExtension().lastPathComponent, ext: plan.outputExtension)
    }

    var plan: CompressionPlan? { currentPlan(output: outputURL) }

    private func currentPlan(output: URL?) -> CompressionPlan? {
        guard let input, phase != .empty else { return nil }
        // First call (output nil) only needs the extension, so use a placeholder path.
        let out = output ?? input.deletingLastPathComponent().appendingPathComponent("placeholder")
        return CompressionPlanner.make(request: request, input: input, output: out, passLog: previewPassLog)
    }

    var commandPreview: String {
        guard let plan, let ffmpeg = ToolLocator.locate("ffmpeg") else { return "" }
        if plan.usesZip { return "/usr/bin/ditto -c -k --sequesterRsrc --keepParent \(input?.path ?? "") \(outputURL?.path ?? "")" }
        return plan.steps.map { step in
            ([ffmpeg.path] + step.arguments).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    var quickTargets: [(title: String, bytes: Int)] {
        var items: [(String, Int)] = [8, 25, 50].map { ("\($0) MB", $0 * 1_000_000) }
        items.append(("50% of original", originalBytes / 2))
        items.append(("25% of original", originalBytes / 4))
        return items.filter { $0.1 > 0 && $0.1 < originalBytes }
    }

    func setTarget(bytes: Int) {
        let mb = Double(bytes) / 1_000_000
        targetText = mb >= 10 ? String(Int(mb.rounded())) : String(format: "%.1f", mb)
    }

    var details: [FileCardDetail] {
        var rows: [FileCardDetail] = []
        if info.kind == .video || info.kind == .audio { rows.append(.init(label: "Duration", value: ByteFormat.duration(info.duration))) }
        if let w = info.width, let h = info.height {
            var value = "\(w) × \(h)"
            if info.kind == .video, let fps = info.fps { value += " · \(String(format: "%.0f", fps)) fps" }
            rows.append(.init(label: "Resolution", value: value))
        }
        let codecs = [info.videoCodec, info.audioCodec].compactMap { $0 }.joined(separator: " + ")
        if !codecs.isEmpty { rows.append(.init(label: "Codecs", value: codecs)) }
        if let b = info.totalBitrate, info.kind == .video || info.kind == .audio { rows.append(.init(label: "Bitrate", value: ByteFormat.bitrate(b))) }
        return rows
    }

    var kindLabel: String {
        switch info.kind {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .other: input.map { $0.hasDirectoryPath ? "Folder" : ($0.pathExtension.isEmpty ? "File" : "\($0.pathExtension.uppercased()) file") } ?? "File"
        }
    }

    // MARK: Actions

    func load(_ url: URL) {
        let url = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { phase = .failed("That file no longer exists."); return }
        reset()
        input = url
        phase = .probing
        Task { [weak self] in
            // Disk walk and ffprobe both run off the main thread.
            async let size = Self.measure(url)
            async let probed = MediaProbe.probe(url)
            async let webp = MediaProbe.encoderAvailable("libwebp")
            let (bytes, media, hasWebP) = await (size, probed, webp)
            guard let self, self.input == url else { return }
            self.originalBytes = bytes
            self.info = media
            self.webpAvailable = hasWebP
            self.applyDefaults()
            self.phase = .ready
        }
    }

    nonisolated static func measure(_ url: URL) async -> Int {
        await Task.detached(priority: .userInitiated) { measureSync(url) }.value
    }

    nonisolated static func measureSync(_ url: URL) -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return CompressorService.fileSize(url) }
        var total = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let item as URL in e { total += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        }
        return total
    }

    private func applyDefaults() {
        let big = originalBytes > 30_000_000
        setTarget(bytes: big ? 25_000_000 : max(originalBytes / 2, 100_000))
        if !webpAvailable { imageFormat = .jpeg }
    }

    func reset() {
        task?.cancel(); handle.cancel()
        phase = .empty; input = nil; info = .other; originalBytes = 0; customOutput = nil
        progress = nil; elapsed = 0
    }

    func chooseOutput() {
        guard let plan, let input else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (outputURL ?? input).lastPathComponent
        panel.directoryURL = input.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            customOutput = url.pathExtension.lowercased() == plan.outputExtension ? url : url.appendingPathExtension(plan.outputExtension)
        }
    }

    func start() {
        guard let input, let output = outputURL else { return }
        guard ToolLocator.locate("ffmpeg") != nil || kind == .other else { phase = .failed(ToolError.toolMissing("FFmpeg").localizedDescription); return }
        let dir: URL
        do { dir = try PrivateTemp.make() } catch { phase = .failed(error.localizedDescription); return }
        tempDir = dir
        let runPlan = CompressionPlanner.make(request: request, input: input, output: output, passLog: dir.appendingPathComponent("pass").path)
        guard runPlan.problem == nil else { return }
        let request = self.request
        handle = ProcessHandle()
        let handle = self.handle
        progress = 0; elapsed = 0; startedAt = Date()
        progressLabel = runPlan.steps.first?.label ?? "Compressing"
        phase = .running
        task = Task { [weak self] in
            do {
                let result = try await CompressorService.run(
                    plan: runPlan, request: request, input: input, output: output, tempDir: dir, handle: handle
                ) { update in
                    Task { @MainActor in self?.apply(update) }
                }
                self?.phase = .done(result)
            } catch is CancellationError {
                self?.phase = .ready
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ update: ProgressUpdate) {
        guard phase == .running else { return }
        progress = update.fraction
        progressLabel = update.label
        elapsed = Date().timeIntervalSince(startedAt)
    }

    func cancel() {
        handle.cancel()
        task?.cancel()
    }
}
