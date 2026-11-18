import Foundation
import XCTest
@testable import FileFoundry

final class CompressorTests: XCTestCase {
    func testBitratePlanDownscalesAndReservesOverhead() {
        // 2 MB over 20 s: ~813 kbps total, 128k audio, 1080p30 needs far more than that.
        let plan = BitratePlanner.planVideo(
            targetBytes: 2_000_000, duration: 20, width: 1920, height: 1080, fps: 30,
            hasAudio: true, sourceAudioCodec: "mp3", sourceAudioBitrate: 128_000)
        XCTAssertTrue(plan.feasible)
        XCTAssertEqual(plan.audioBitrate, 128_000)
        XCTAssertEqual(plan.videoBitrate, Int(2_000_000.0 * 8 * 0.97 / 20) - 128_000)
        XCTAssertEqual(plan.scaleHeight, 540)
        XCTAssertEqual(plan.outputWidth, 960)
    }

    func testAudioLadderStepsDownWhenTight() {
        let plan = BitratePlanner.planVideo(
            targetBytes: 600_000, duration: 20, width: 1280, height: 720, fps: 30,
            hasAudio: true, sourceAudioCodec: "aac", sourceAudioBitrate: 40_000)
        XCTAssertTrue(plan.feasible)
        XCTAssertTrue(plan.copyAudio)
        XCTAssertEqual(plan.audioBitrate, 40_000)
    }

    func testImpossibleTargetSuggestsMinimum() {
        let plan = BitratePlanner.planVideo(
            targetBytes: 50_000, duration: 600, width: 1920, height: 1080, fps: 30,
            hasAudio: true, sourceAudioCodec: nil, sourceAudioBitrate: nil)
        XCTAssertFalse(plan.feasible)
        XCTAssertNotNil(plan.minimumTargetBytes)
        XCTAssertNotNil(plan.problem)
    }

    func testTargetValidationRejectsLargerThanOriginal() {
        XCTAssertNotNil(BitratePlanner.validateTarget(targetBytes: 10, originalBytes: 10))
        XCTAssertNil(BitratePlanner.validateTarget(targetBytes: 9, originalBytes: 10))
    }

    func testAudioPlanClamps() {
        XCTAssertEqual(BitratePlanner.planAudio(targetBytes: 100_000_000, duration: 60).bitrate, 320_000)
        XCTAssertFalse(BitratePlanner.planAudio(targetBytes: 1_000, duration: 600).feasible)
    }

    func testOutputNamingNeverOverwrites() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/clip (compressed).mp4", "/tmp/x/clip (compressed) 2.mp4"]
        let url = OutputNaming.uniqueURL(directory: dir, baseName: "clip", ext: "mp4") { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "clip (compressed) 3.mp4")
    }

    func testProgressParsing() {
        XCTAssertEqual(FFmpegProgress.seconds(from: "out_time_us=2500000"), 2.5)
        XCTAssertEqual(FFmpegProgress.seconds(from: "out_time_ms=1000000"), 1)
        XCTAssertNil(FFmpegProgress.seconds(from: "out_time_us=N/A"))
        XCTAssertNil(FFmpegProgress.seconds(from: "frame=10"))
        XCTAssertEqual(FFmpegProgress.fraction(from: "out_time_us=5000000", duration: 10), 0.5)
        XCTAssertEqual(FFmpegProgress.fraction(from: "out_time_us=50000000", duration: 10), 1)
    }

    func testProbeParsingClassifies() throws {
        let video = #"{"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"avg_frame_rate":"30000/1001","duration":"20.0","disposition":{"attached_pic":0}},{"codec_type":"audio","codec_name":"aac","bit_rate":"128000"}],"format":{"format_name":"mov,mp4","duration":"20.0","bit_rate":"5000000"}}"#
        let info = try MediaProbe.parse(Data(video.utf8))
        XCTAssertEqual(info.kind, .video)
        XCTAssertEqual(info.height, 1080)
        XCTAssertEqual(info.audioBitrate, 128_000)
        XCTAssertEqual(info.fps ?? 0, 29.97, accuracy: 0.01)

        let image = #"{"streams":[{"codec_type":"video","codec_name":"png","width":10,"height":10}],"format":{"format_name":"png_pipe"}}"#
        XCTAssertEqual(try MediaProbe.parse(Data(image.utf8)).kind, .image)

        let cover = #"{"streams":[{"codec_type":"audio","codec_name":"mp3"},{"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}}],"format":{"format_name":"mp3","duration":"180"}}"#
        XCTAssertEqual(try MediaProbe.parse(Data(cover.utf8)).kind, .audio)

        XCTAssertEqual(try MediaProbe.parse(Data(#"{"streams":[],"format":{}}"#.utf8)).kind, .other)
    }

    func testHardwareQualityUsesVideoToolbox() {
        var info = MediaInfo(); info.kind = .video; info.duration = 10; info.width = 1280; info.height = 720
        let request = CompressionRequest(
            info: info, originalBytes: 10_000_000, mode: .quality, targetBytes: 0, codec: .hevc, preset: .balanced,
            image: ImageSettings(), hardware: true)
        let plan = CompressionPlanner.make(request: request, input: URL(fileURLWithPath: "/tmp/a.mov"), output: URL(fileURLWithPath: "/tmp/b.mp4"), passLog: "/tmp/p")
        let args = plan.steps[0].arguments
        XCTAssertTrue(args.contains("hevc_videotoolbox"))
        XCTAssertFalse(args.contains("libx265"))
        XCTAssertEqual(plan.steps.count, 1)
        // Target size stays two-pass software even when hardware is requested.
        var target = request; target.mode = .targetSize; target.targetBytes = 2_000_000
        let two = CompressionPlanner.make(request: target, input: URL(fileURLWithPath: "/tmp/a.mov"), output: URL(fileURLWithPath: "/tmp/b.mp4"), passLog: "/tmp/p")
        XCTAssertEqual(two.steps.count, 2)
        XCTAssertTrue(two.steps[1].arguments.contains("libx265"))
    }

    func testOutputSafetyRefusesInput() {
        let url = URL(fileURLWithPath: "/tmp/a.mp4")
        XCTAssertThrowsError(try OutputSafety.validate(input: url, output: url))
    }

    func testOutputSafetyRefusesZipInsideFolder() throws {
        let dir = try PrivateTemp.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try OutputSafety.validate(input: dir, output: dir.appendingPathComponent("inside.zip")))
    }

    func testOutputSafetyIsCaseInsensitiveAndResolvesSymlinks() throws {
        let dir = try PrivateTemp.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        // Different case of the archived folder, and a symlinked parent that resolves into it.
        XCTAssertThrowsError(try OutputSafety.validate(input: folder, output: dir.appendingPathComponent("DOCS/out.zip")))
        XCTAssertThrowsError(try OutputSafety.validate(input: folder, output: alias.appendingPathComponent("out.zip")))
        XCTAssertThrowsError(try OutputSafety.validate(input: folder, output: dir.appendingPathComponent("docs")))
        XCTAssertNoThrow(try OutputSafety.validate(input: folder, output: dir.appendingPathComponent("Docs2.zip")))
        XCTAssertNoThrow(try OutputSafety.validate(input: folder, output: dir.appendingPathComponent("Docs.zip")))
    }

    func testPublishMovesStagedFileAndNeverReplacesExistingDestination() throws {
        let dir = try PrivateTemp.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("staged.bin")
        try Data("new".utf8).write(to: staged)
        let destination = dir.appendingPathComponent("clip (compressed).mp4")
        try Data("precious".utf8).write(to: destination)
        try Data("second".utf8).write(to: dir.appendingPathComponent("clip (compressed) 2.mp4"))

        let published = try OutputPublisher.publish(staged: staged, to: destination)
        XCTAssertEqual(published.lastPathComponent, "clip (compressed) 3.mp4")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "precious")
        XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        // A dangling symlink at the destination is also "taken", not followed.
        let staged2 = dir.appendingPathComponent("staged2.bin")
        try Data("n2".utf8).write(to: staged2)
        let trap = dir.appendingPathComponent("trap.mp4")
        try FileManager.default.createSymbolicLink(at: trap, withDestinationURL: dir.appendingPathComponent("nowhere"))
        XCTAssertEqual(try OutputPublisher.publish(staged: staged2, to: trap).lastPathComponent, "trap 2.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("nowhere").path))
    }

    func testRunnerPublishesZipFromTempAndKeepsExistingDestination() async throws {
        let dir = try PrivateTemp.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: input)
        let output = dir.appendingPathComponent("note.txt (compressed).zip")
        try Data("precious".utf8).write(to: output)
        let work = try PrivateTemp.make()
        let result = try await MediaRunner.run(
            plan: CompressionPlanner.zip(), originalBytes: 5, input: input, output: output, tempDir: work, handle: ProcessHandle()) { _ in }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "precious")
        XCTAssertEqual(result.outputURL.lastPathComponent, "note.txt (compressed) 2.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testFailedRunLeavesUserFolderUntouched() async throws {
        let dir = try PrivateTemp.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("missing-folder")
        let output = dir.appendingPathComponent("out.zip")
        let work = try PrivateTemp.make()
        do {
            _ = try await MediaRunner.run(
                plan: CompressionPlanner.zip(), originalBytes: 0, input: input, output: output, tempDir: work, handle: ProcessHandle()) { _ in }
            XCTFail("ditto must fail for a missing input")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testEveryFFmpegInputIsPrecededByProtocolWhitelist() {
        var info = MediaInfo(); info.kind = .video; info.duration = 10; info.width = 1280; info.height = 720; info.audioCodec = "aac"
        let input = URL(fileURLWithPath: "/tmp/a:b.mov"), output = URL(fileURLWithPath: "/tmp/b.mp4")
        var plans: [CompressionPlan] = []
        for mode in [CompressionMode.targetSize, .quality] {
            for hardware in [false, true] {
                let request = CompressionRequest(info: info, originalBytes: 10_000_000, mode: mode, targetBytes: 2_000_000, codec: .h264,
                                                 preset: .balanced, image: ImageSettings(), hardware: hardware)
                plans.append(CompressionPlanner.make(request: request, input: input, output: output, passLog: "/tmp/p"))
            }
        }
        var audio = info; audio.kind = .audio
        plans.append(CompressionPlanner.make(request: CompressionRequest(info: audio, originalBytes: 1_000_000, mode: .quality, targetBytes: 0, codec: .h264, preset: .balanced, image: ImageSettings()), input: input, output: output, passLog: "/tmp/p"))
        var image = info; image.kind = .image
        plans.append(CompressionPlanner.make(request: CompressionRequest(info: image, originalBytes: 1_000_000, mode: .quality, targetBytes: 0, codec: .h264, preset: .balanced, image: ImageSettings()), input: input, output: output, passLog: "/tmp/p"))
        var argumentLists = plans.flatMap { $0.steps.map(\.arguments) }
        argumentLists.append(CompressionPlanner.imageArguments(input: input, output: output, settings: ImageSettings(), quality: 50))
        for preset in ConverterPreset.allCases where !preset.usesSips {
            argumentLists.append(ConversionPlanner.make(preset: preset, info: info, input: input, output: output).steps[0].arguments)
        }
        XCTAssertGreaterThan(argumentLists.count, 10)
        for args in argumentLists {
            let positions = args.indices.filter { args[$0] == "-i" }
            XCTAssertEqual(positions.count, 1, "\(args)")
            for i in positions {
                XCTAssertGreaterThanOrEqual(i, 2)
                XCTAssertEqual(Array(args[(i - 2)..<i]), ["-protocol_whitelist", "file,pipe"], "\(args)")
                XCTAssertEqual(args[i + 1], "/tmp/a:b.mov", "input must be an absolute path")
            }
        }
    }

    func testFFprobeArgumentsWhitelistProtocolsAndEndOptions() {
        let args = MediaProbe.probeArguments(for: URL(fileURLWithPath: "/tmp/-weird.mov"))
        let whitelist = try? XCTUnwrap(args.firstIndex(of: "-protocol_whitelist"))
        XCTAssertEqual(args[(whitelist ?? 0) + 1], "file,pipe")
        XCTAssertLessThan(whitelist ?? .max, args.firstIndex(of: "--") ?? 0)
        XCTAssertEqual(args.last, "/tmp/-weird.mov")
        XCTAssertEqual(args[args.count - 2], "--")
    }

    func testEncoderCapabilitiesParse() {
        let text = """
        Encoders:
         V..... = Video
         ------
         V....D libx264              libx264 H.264
         V....D h264_videotoolbox    VideoToolbox H.264 Encoder
         A....D libopus              libopus Opus
        """
        let caps = EncoderCapabilities.parse(text)
        XCTAssertTrue(caps.has("libx264"))
        XCTAssertTrue(caps.hardwareH264)
        XCTAssertFalse(caps.hardwareHEVC)
        XCTAssertFalse(caps.has("libwebp"))
        XCTAssertTrue(EncoderCapabilities().has("libwebp"), "unknown capabilities must not hide options")
    }

    func testEndToEndTargetSize() async throws {
        guard let ffmpeg = ToolLocator.locate("ffmpeg"), ToolLocator.locate("ffprobe") != nil else {
            throw XCTSkip("ffmpeg/ffprobe not installed")
        }
        let dir = try PrivateTemp.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("ff-test.mp4")
        let gen = try await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440", "-t", "20", "-c:v", "libx264", "-crf", "10", "-c:a", "aac", input.path])
        XCTAssertTrue(gen.succeeded, gen.stderrTail)

        let info = await MediaProbe.probe(input)
        XCTAssertEqual(info.kind, .video)
        let original = MediaRunner.fileSize(input)
        let target = 2_000_000
        let request = CompressionRequest(
            info: info, originalBytes: original, mode: .targetSize, targetBytes: target, codec: .h264,
            preset: .balanced, image: ImageSettings())
        let work = try PrivateTemp.make()
        let output = dir.appendingPathComponent("ff-test (compressed).mp4")
        let plan = CompressionPlanner.make(request: request, input: input, output: MediaRunner.stagedURL(tempDir: work, ext: "mp4"), passLog: work.appendingPathComponent("pass").path)
        XCTAssertNil(plan.problem)
        let result = try await MediaRunner.run(
            plan: plan, originalBytes: original, input: input, output: output, tempDir: work, handle: ProcessHandle()) { _ in }
        print("E2E input=\(original) target=\(target) output=\(result.newBytes) summary=\(plan.summary)")
        XCTAssertLessThanOrEqual(result.newBytes, target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), "temp dir must be removed")
    }
}
