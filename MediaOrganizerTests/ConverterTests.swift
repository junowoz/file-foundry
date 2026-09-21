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
            XCTAssertFalse(preset.arguments.joined(separator: " ").contains("|"))
            XCTAssertFalse(preset.arguments.joined(separator: " ").contains(";"))
        }
    }

    func testPresetsExposeExpectedExtensionsAndCodecs() {
        XCTAssertEqual(ConverterPreset.allCases.count, 9)
        XCTAssertEqual(ConverterPreset.videoH264.fileExtension, "mp4")
        XCTAssertTrue(ConverterPreset.videoHEVC.arguments.contains("libx265"))
        XCTAssertTrue(ConverterPreset.videoWebM.arguments.contains("libvpx-vp9"))
        XCTAssertEqual(ConverterPreset.audioFLAC.fileExtension, "flac")
        XCTAssertEqual(ConverterPreset.imagePNG.fileExtension, "png")
        for preset in ConverterPreset.allCases { XCTAssertFalse(preset.arguments.contains("-y")); XCTAssertTrue(preset.arguments.contains { $0.hasPrefix("-") }) }
    }

    func testInstalledFFmpegProbe() throws {
        guard ConverterExecutable.locate() != nil else {
            throw XCTSkip("FFmpeg is not installed on this Mac.")
        }
        XCTAssertTrue(ConverterExecutable.probe())
    }
}
