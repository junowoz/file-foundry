import Foundation
import XCTest
@testable import FileFoundry

final class ConverterTests: XCTestCase {
    func testDetectorUsesPathWhenKnownLocationsAreMissing() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent("ffmpeg")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.path, contents: Data())
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let detected = ConverterExecutable.locate(environment: ["PATH": root.path])
        XCTAssertNotNil(detected)
        if !["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].contains(detected?.path) {
            XCTAssertEqual(detected?.path, bin.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testPresetsNeverIncludeShellSyntax() {
        for preset in ConverterPreset.allCases {
            let joined = preset.arguments.joined(separator: " ")
            for bad in ["|", "`", "$(", "&&"] { XCTAssertFalse(joined.contains(bad), "\(preset) contains \(bad)") }
            XCTAssertFalse(preset.arguments.contains("-y"))
            XCTAssertTrue(preset.arguments.contains { $0.hasPrefix("-") })
        }
    }

    func testPresetsExposeExpectedExtensionsAndCodecs() {
        XCTAssertEqual(ConverterPreset.videoH264.fileExtension, "mp4")
        XCTAssertTrue(ConverterPreset.videoHEVC.arguments.contains("libx265"))
        XCTAssertTrue(ConverterPreset.videoWebM.arguments.contains("libvpx-vp9"))
        XCTAssertEqual(ConverterPreset.audioFLAC.fileExtension, "flac")
        XCTAssertEqual(ConverterPreset.imagePNG.fileExtension, "png")
        XCTAssertEqual(ConverterPreset.imageHEIC.fileExtension, "heic")
        XCTAssertTrue(ConverterPreset.imageHEIC.usesSips)
    }

    func testInstalledFFmpegProbe() throws {
        guard ConverterExecutable.locate() != nil else { throw XCTSkip("FFmpeg is not installed on this Mac.") }
        XCTAssertTrue(ConverterExecutable.probe())
    }

    // MARK: Type to actions

    func testActionsByType() {
        XCTAssertEqual(MediaActions.available(for: .video), [.compress, .convert])
        XCTAssertEqual(MediaActions.available(for: .audio), [.compress, .convert])
        XCTAssertEqual(MediaActions.available(for: .image), [.compress, .convert])
        XCTAssertEqual(MediaActions.available(for: .other), [.zip])
    }

    func testDefaultActions() {
        func info(_ kind: ContentKind, codec: String? = nil) -> MediaInfo { var i = MediaInfo(); i.kind = kind; i.videoCodec = codec; return i }
        XCTAssertEqual(MediaActions.defaultAction(for: info(.video)), .compress)
        XCTAssertEqual(MediaActions.defaultAction(for: info(.audio)), .compress)
        XCTAssertEqual(MediaActions.defaultAction(for: info(.image, codec: "png")), .convert)
        XCTAssertEqual(MediaActions.defaultAction(for: info(.image, codec: "mjpeg")), .compress)
        XCTAssertEqual(MediaActions.defaultAction(for: info(.other)), .zip)
    }

    func testConvertTargetsFilteredByTypeAndEncoders() {
        let full = EncoderCapabilities(encoders: ["libx264", "libx265", "libvpx-vp9", "gif", "libmp3lame", "aac", "pcm_s16le", "flac", "libopus", "mjpeg", "png", "libwebp"])
        XCTAssertTrue(ConverterPreset.available(for: .video, capabilities: full).contains(.audioMP3), "video can extract audio")
        XCTAssertFalse(ConverterPreset.available(for: .video, capabilities: full).contains(.imagePNG))
        XCTAssertTrue(ConverterPreset.available(for: .audio, capabilities: full).contains(.audioOpus))
        XCTAssertTrue(ConverterPreset.available(for: .image, capabilities: full).contains(.imageWebP))
        XCTAssertTrue(ConverterPreset.available(for: .other, capabilities: full).isEmpty)

        let lean = EncoderCapabilities(encoders: ["libx264", "aac", "mjpeg", "png"])
        XCTAssertFalse(ConverterPreset.available(for: .audio, capabilities: lean).contains(.audioOpus))
        XCTAssertFalse(ConverterPreset.available(for: .image, capabilities: lean).contains(.imageWebP))
        XCTAssertTrue(ConverterPreset.available(for: .image, capabilities: lean).contains(.imageHEIC), "HEIC uses sips, not ffmpeg")
    }

    func testConversionPlanUsesArgumentArraysAndSips() {
        var info = MediaInfo(); info.kind = .video; info.duration = 5
        let input = URL(fileURLWithPath: "/tmp/in put.mov"), output = URL(fileURLWithPath: "/tmp/out.mp3")
        let plan = ConversionPlanner.make(preset: .audioMP3, info: info, input: input, output: output)
        XCTAssertEqual(plan.problem, "This video has no audio track.")
        info.audioCodec = "aac"
        let ok = ConversionPlanner.make(preset: .audioMP3, info: info, input: input, output: output)
        XCTAssertNil(ok.problem)
        XCTAssertTrue(ok.steps[0].arguments.contains(input.path), "paths are single arguments, never shell-split")
        XCTAssertTrue(ok.steps[0].arguments.contains("-n"))
        XCTAssertEqual(ok.duration, 5)
        var image = MediaInfo(); image.kind = .image
        let heic = ConversionPlanner.make(preset: .imageHEIC, info: image, input: input, output: URL(fileURLWithPath: "/tmp/o.heic"))
        XCTAssertEqual(heic.steps[0].tool, .sips)
    }

    // MARK: Queue state

    private func queueWithItems(_ names: [String]) -> (MediaQueue, [UUID]) {
        var queue = MediaQueue()
        let added = queue.add(names.map { URL(fileURLWithPath: "/tmp/q/\($0)") })
        for item in added { queue.setProbed(item.id, info: MediaInfo(kind: .video, duration: 10), bytes: 1_000) }
        return (queue, added.map(\.id))
    }

    private func result(_ id: String, new: Int = 400) -> CompressionResult {
        CompressionResult(outputURL: URL(fileURLWithPath: "/tmp/q/\(id)-out.mp4"), originalBytes: 1_000, newBytes: new, targetBytes: nil)
    }

    func testQueueIgnoresDuplicatesAndStartsProbing() {
        var queue = MediaQueue()
        XCTAssertEqual(queue.add([URL(fileURLWithPath: "/tmp/a.mp4"), URL(fileURLWithPath: "/tmp/a.mp4")]).count, 1)
        XCTAssertEqual(queue.add([URL(fileURLWithPath: "/tmp/a.mp4")]).count, 0)
        XCTAssertTrue(queue.isProbing)
        XCTAssertTrue(queue.kinds.isEmpty, "kind is unknown until probed")
    }

    func testQueueRunsOneAtATimeInOrder() {
        var (queue, ids) = queueWithItems(["a.mp4", "b.mp4", "c.mp4"])
        XCTAssertEqual(queue.startableCount, 3)
        XCTAssertEqual(queue.enqueue(), 3)
        XCTAssertEqual(queue.nextQueued()?.id, ids[0])
        queue.markRunning(ids[0], label: "Encoding")
        XCTAssertNil(queue.nextQueued(), "never two encodes at once")
        queue.updateProgress(ids[0], progress: 0.5, label: "Encoding", eta: 3)
        XCTAssertEqual(queue.item(ids[0])?.state, .running(progress: 0.5, label: "Encoding", eta: 3))
        queue.finish(ids[0], result: result("a"))
        XCTAssertEqual(queue.nextQueued()?.id, ids[1])
        queue.markRunning(ids[1], label: "Encoding")
        queue.fail(ids[1], message: "boom")
        XCTAssertEqual(queue.item(ids[1])?.state, .failed("boom"))
        XCTAssertEqual(queue.nextQueued()?.id, ids[2])
        XCTAssertTrue(queue.isBusy)
        queue.markRunning(ids[2], label: "Encoding")
        queue.finish(ids[2], result: result("c"))
        XCTAssertFalse(queue.isBusy)
        XCTAssertEqual(queue.doneCount, 2)
    }

    func testCancelReturnsActiveItemsToReadyAndKeepsFinished() {
        var (queue, ids) = queueWithItems(["a.mp4", "b.mp4", "c.mp4"])
        queue.enqueue()
        queue.markRunning(ids[0], label: "x")
        queue.finish(ids[0], result: result("a"))
        queue.markRunning(ids[1], label: "x")
        queue.cancelAll()
        XCTAssertEqual(queue.item(ids[1])?.state, .ready)
        XCTAssertEqual(queue.item(ids[2])?.state, .ready)
        if case .done = queue.item(ids[0])?.state {} else { XCTFail("finished item must stay done") }
        queue.updateProgress(ids[1], progress: 0.9, label: "late", eta: nil)
        XCTAssertEqual(queue.item(ids[1])?.state, .ready, "late progress after cancel is ignored")
    }

    func testRetryAndClearFinished() {
        var (queue, ids) = queueWithItems(["a.mp4", "b.mp4"])
        queue.enqueue()
        queue.markRunning(ids[0], label: "x"); queue.fail(ids[0], message: "bad")
        queue.markRunning(ids[1], label: "x"); queue.finish(ids[1], result: result("b"))
        XCTAssertEqual(queue.startableCount, 1, "failed items can be retried; done ones cannot")
        XCTAssertEqual(queue.enqueue(), 1)
        XCTAssertEqual(queue.item(ids[0])?.state, .queued)
        queue.cancelAll()
        queue.clearFinished()
        XCTAssertEqual(queue.items.map(\.id), [ids[0]])
        queue.remove(ids[0])
        XCTAssertTrue(queue.isEmpty)
    }

    func testKindsAreGroupedInStableOrder() {
        var queue = MediaQueue()
        let added = queue.add(["a.jpg", "b.mp4", "c.zip", "d.mp4"].map { URL(fileURLWithPath: "/tmp/\($0)") })
        let kinds: [ContentKind] = [.image, .video, .other, .video]
        for (item, kind) in zip(added, kinds) { queue.setProbed(item.id, info: MediaInfo(kind: kind), bytes: 1) }
        XCTAssertEqual(queue.kinds, [.video, .image, .other])
        XCTAssertEqual(queue.items(of: .video).count, 2)
    }

    func testTargetFractionAppliesPerFile() {
        var s = KindSettings(info: MediaInfo(kind: .video), originalBytes: 10_000_000)
        XCTAssertEqual(s.targetFraction, 0.5)
        XCTAssertEqual(s.targetBytes(original: 8_000_000), 4_000_000)
        s.setTarget(megabytes: 25)
        XCTAssertNil(s.targetFraction)
        XCTAssertEqual(s.targetBytes(original: 8_000_000), 25_000_000)
        s.targetText = ""
        XCTAssertTrue(s.targetIsBlank)
    }
}
