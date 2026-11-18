import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MediaModel {
    private(set) var queue = MediaQueue()
    var settings: [ContentKind: KindSettings] = [:]
    var outputDirectory: URL?
    private(set) var capabilities = EncoderCapabilities()
    private(set) var ffmpegMissing = ToolLocator.locate("ffmpeg") == nil

    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var handle = ProcessHandle()
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private let probeLimit = 4

    init() {
        Task { [weak self] in
            let caps = await EncoderCapabilities.load()
            self?.capabilities = caps
            self?.ffmpegMissing = ToolLocator.locate("ffmpeg") == nil
        }
    }

    // MARK: Adding files

    /// Adds files and probes them, at most `probeLimit` at a time, off the main actor.
    func add(_ urls: [URL]) {
        let added = queue.add(urls.filter { FileManager.default.fileExists(atPath: $0.path) })
        guard !added.isEmpty else { return }
        let limit = probeLimit
        Task { [weak self] in
            await withTaskGroup(of: (UUID, MediaInfo, Int).self) { group in
                var pending = added.makeIterator()
                func launch(_ item: MediaItem) {
                    group.addTask { await Self.inspect(id: item.id, url: item.url) }
                }
                for _ in 0..<limit { if let next = pending.next() { launch(next) } }
                for await (id, info, bytes) in group {
                    self?.probed(id, info: info, bytes: bytes)
                    if let next = pending.next() { launch(next) }
                }
            }
        }
    }

    nonisolated private static func inspect(id: UUID, url: URL) async -> (UUID, MediaInfo, Int) {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        async let bytes = Task.detached(priority: .userInitiated) { MediaRunner.measure(url) }.value
        let info = isDir.boolValue ? MediaInfo.other : await MediaProbe.probe(url)
        return (id, info, await bytes)
    }

    private func probed(_ id: UUID, info: MediaInfo, bytes: Int) {
        queue.setProbed(id, info: info, bytes: bytes)
        if settings[info.kind] == nil { settings[info.kind] = KindSettings(info: info, originalBytes: bytes) }
    }

    func remove(_ id: UUID) {
        if queue.item(id)?.isRunning == true { cancel() }
        queue.remove(id)
    }

    func clearFinished() { queue.clearFinished() }

    func removeAll() {
        cancel()
        queue.removeAll()
    }

    // MARK: Settings

    func binding(for kind: ContentKind) -> Binding<KindSettings> {
        Binding(
            get: { self.settings[kind] ?? KindSettings(info: MediaInfo(kind: kind), originalBytes: 0) },
            set: { self.settings[kind] = $0 })
    }

    func convertPresets(for kind: ContentKind) -> [ConverterPreset] {
        ConverterPreset.available(for: kind, capabilities: capabilities)
    }

    var webpAvailable: Bool { capabilities.has("libwebp") }

    func hardwareAvailable(codec: VideoCodecChoice) -> Bool {
        codec == .h264 ? capabilities.hardwareH264 : capabilities.hardwareHEVC
    }

    /// The plan for the first file of a kind, shown as a preview of what will run for all of them.
    func preview(for kind: ContentKind) -> (plan: CompressionPlan, command: String)? {
        guard let item = queue.items(of: kind).first, let s = settings[kind] else { return nil }
        let placeholder = item.url.deletingLastPathComponent().appendingPathComponent("preview")
        var plan = MediaJobPlanner.plan(
            settings: s, info: item.info, originalBytes: item.originalBytes, input: item.url, output: placeholder,
            passLog: "<pass-log>", capabilities: capabilities)
        let output = MediaJobPlanner.outputURL(for: item.url, plan: plan, action: s.action, directory: outputDirectory)
        plan = MediaJobPlanner.plan(
            settings: s, info: item.info, originalBytes: item.originalBytes, input: item.url, output: output,
            passLog: "<pass-log>", capabilities: capabilities)
        let command: String
        if plan.usesZip {
            command = ""
        } else {
            command = plan.steps.map { step in
                if step.tool == .decode { return "# macOS reads the image: \(step.arguments.joined(separator: " → "))" }
                let exe = step.tool == .sips ? "/usr/bin/sips" : (ToolLocator.locate("ffmpeg")?.path ?? "ffmpeg")
                return ([exe] + step.arguments).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
            }.joined(separator: "\n")
        }
        return (plan, command)
    }

    var canStart: Bool {
        guard !queue.isBusy, queue.startableCount > 0 else { return false }
        return !settings.contains { kind, s in s.targetIsBlank && queue.items(of: kind).contains { !$0.isFinished } }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.presentAsSheet { [weak self] ok in
            guard ok, let url = panel.url else { return }
            self?.outputDirectory = url
        }
    }

    // MARK: Running

    func start() {
        guard canStart, queue.enqueue() > 0 else { return }
        runner = Task { [weak self] in
            while let self, !Task.isCancelled, let next = self.queue.nextQueued() {
                await self.run(next)
            }
        }
    }

    func cancel() {
        runner?.cancel()
        handle.cancel()
        queue.cancelAll()
    }

    private func run(_ item: MediaItem) async {
        let id = item.id
        guard let s = settings[item.kind] else { queue.fail(id, message: "Missing settings."); return }
        let tempDir: URL
        do { tempDir = try PrivateTemp.make() } catch { queue.fail(id, message: error.localizedDescription); return }
        let passLog = tempDir.appendingPathComponent("pass").path
        let probe = MediaJobPlanner.plan(
            settings: s, info: item.info, originalBytes: item.originalBytes, input: item.url,
            output: tempDir.appendingPathComponent("preview"), passLog: passLog, capabilities: capabilities)
        // Naming happens now, not at queue time, so earlier outputs in the same run are never overwritten.
        let output = MediaJobPlanner.outputURL(for: item.url, plan: probe, action: s.action, directory: outputDirectory)
        // Tools write into the private temp dir; the runner publishes the result without replacing anything.
        let plan = MediaJobPlanner.plan(
            settings: s, info: item.info, originalBytes: item.originalBytes, input: item.url,
            output: MediaRunner.stagedURL(tempDir: tempDir, ext: probe.outputExtension),
            passLog: passLog, capabilities: capabilities)
        if let problem = plan.problem {
            try? FileManager.default.removeItem(at: tempDir)
            queue.fail(id, message: problem); return
        }
        // Image conversions run on macOS alone; only ffmpeg steps need FFmpeg installed.
        if plan.needsFFmpeg, ToolLocator.locate("ffmpeg") == nil {
            try? FileManager.default.removeItem(at: tempDir)
            queue.fail(id, message: ToolError.toolMissing("FFmpeg").localizedDescription); return
        }
        handle = ProcessHandle()
        let handle = self.handle
        startedAt = Date()
        queue.markRunning(id, label: plan.steps.first?.label ?? "Creating ZIP archive")
        do {
            let result = try await MediaRunner.run(
                plan: plan, originalBytes: item.originalBytes, input: item.url, output: output, tempDir: tempDir, handle: handle
            ) { update in
                Task { @MainActor in self.apply(id, update) }
            }
            queue.finish(id, result: result)
        } catch is CancellationError {
            // cancel() already returned every active item to ready; the runner removed the partial output.
        } catch {
            queue.fail(id, message: error.localizedDescription)
        }
    }

    private func apply(_ id: UUID, _ update: ProgressUpdate) {
        var eta: TimeInterval?
        if let f = update.fraction, f > 0.03, f < 1 {
            eta = Date().timeIntervalSince(startedAt) * (1 - f) / f
        }
        queue.updateProgress(id, progress: update.fraction, label: update.label, eta: eta)
    }
}
