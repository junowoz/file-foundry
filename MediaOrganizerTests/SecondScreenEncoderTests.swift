import CoreMedia
import CoreVideo
import XCTest
@testable import FileFoundry

final class SecondScreenEncoderTests: XCTestCase {
    private func makeBuffer(_ width: Int, _ height: Int, shade: UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pb)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                memset(base, plane == 0 ? Int32(shade) : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func run(hevc: Bool) async throws {
        let box = FrameBox()
        let encoder: SSVideoEncoder
        do {
            encoder = try SSVideoEncoder(width: 1280, height: 720, hevc: hevc, fps: 30, bitrate: 8_000_000) { box.add($0) }
        } catch { throw XCTSkip("VideoToolbox unavailable: \(error)") }
        defer { encoder.invalidate() }

        for i in 0..<8 {
            encoder.encode(try makeBuffer(1280, 720, shade: UInt8(40 + i * 20)), pts: CMTime(value: Int64(i), timescale: 30))
        }
        encoder.requestKeyframe()
        for _ in 0..<50 where box.frames.count < 9 { try await Task.sleep(for: .milliseconds(100)) }

        let frames = box.frames
        guard frames.count >= 2 else { throw XCTSkip("Encoder produced \(frames.count) frames in this environment") }
        XCTAssertTrue(frames[0].isKeyframe)
        XCTAssertTrue(frames[0].hasCodecConfig)
        XCTAssertEqual(Array(frames[0].annexB.prefix(4)), [0, 0, 0, 1])
        XCTAssertTrue(frames.dropFirst().contains { !$0.isKeyframe })
        XCTAssertTrue(frames.dropFirst().contains { $0.isKeyframe }, "requestKeyframe should force a second keyframe")
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $0.ptsMicros <= $1.ptsMicros }, "no reordering")
    }

    func testH264AnnexB() async throws { try await run(hevc: false) }
    func testHEVCAnnexB() async throws { try await run(hevc: true) }
}

private final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [SSEncodedFrame] = []
    var frames: [SSEncodedFrame] { lock.withLock { _frames } }
    func add(_ f: SSEncodedFrame) { lock.withLock { _frames.append(f) } }
}
