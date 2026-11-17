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

    func testOutputSafetyRefusesInput() {
        let url = URL(fileURLWithPath: "/tmp/a.mp4")
        XCTAssertThrowsError(try OutputSafety.validate(input: url, output: url))
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
        let original = CompressorService.fileSize(input)
        let target = 2_000_000
        let request = CompressionRequest(
            info: info, originalBytes: original, mode: .targetSize, targetBytes: target, codec: .h264,
            preset: .balanced, image: ImageSettings())
        let work = try PrivateTemp.make()
        let output = dir.appendingPathComponent("ff-test (compressed).mp4")
        let plan = CompressionPlanner.make(request: request, input: input, output: output, passLog: work.appendingPathComponent("pass").path)
        XCTAssertNil(plan.problem)
        let result = try await CompressorService.run(
            plan: plan, request: request, input: input, output: output, tempDir: work, handle: ProcessHandle()) { _ in }
        print("E2E input=\(original) target=\(target) output=\(result.newBytes) summary=\(plan.summary)")
        XCTAssertLessThanOrEqual(result.newBytes, target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), "temp dir must be removed")
    }
}
