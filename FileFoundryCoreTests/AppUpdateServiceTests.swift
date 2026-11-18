import Foundation
@testable import FileFoundryCore
import XCTest

final class AppUpdateServiceTests: XCTestCase {
    func testVersionComparisonTreatsLatestPatchAsNewer() {
        XCTAssertGreaterThan(AppVersion("0.1.2"), AppVersion("0.1.1"))
        XCTAssertGreaterThan(AppVersion("1.0.0"), AppVersion("0.9.9"))
        XCTAssertEqual(AppVersion("v0.1.1"), AppVersion("0.1.1"))
    }

    private func releaseJSON(dmgURL: String, sumsURL: String) -> Data {
        Data(
            """
            {
              "tag_name": "v1.3.0",
              "html_url": "https://github.com/junowoz/file-foundry/releases/tag/v1.3.0",
              "draft": false,
              "prerelease": false,
              "body": "Release notes",
              "assets": [
                { "name": "FileFoundry.dmg", "browser_download_url": "\(dmgURL)" },
                { "name": "FileFoundry-Android.apk", "browser_download_url": "https://github.com/junowoz/file-foundry/releases/download/v1.3.0/FileFoundry-Android.apk" },
                { "name": "SHA256SUMS", "browser_download_url": "\(sumsURL)" }
              ]
            }
            """.utf8
        )
    }

    func testReleaseParserSelectsDMGAndSHA256SUMS() throws {
        let base = "https://github.com/junowoz/file-foundry/releases/download/v1.3.0"
        let release = try AppUpdateService.release(from: releaseJSON(dmgURL: "\(base)/FileFoundry.dmg", sumsURL: "\(base)/SHA256SUMS"))

        XCTAssertEqual(release.version, "1.3.0")
        XCTAssertEqual(release.packageURL.lastPathComponent, "FileFoundry.dmg")
        XCTAssertEqual(release.checksumURL.lastPathComponent, "SHA256SUMS")
    }

    func testReleaseParserRejectsMissingChecksumAsset() throws {
        let json = Data(
            """
            {
              "tag_name": "v1.3.0",
              "html_url": "https://github.com/junowoz/file-foundry/releases/tag/v1.3.0",
              "draft": false,
              "prerelease": false,
              "assets": [
                { "name": "FileFoundry.dmg", "browser_download_url": "https://github.com/junowoz/file-foundry/releases/download/v1.3.0/FileFoundry.dmg" }
              ]
            }
            """.utf8
        )

        XCTAssertThrowsError(try AppUpdateService.release(from: json))
    }

    func testReleaseParserRejectsNonGitHubAssets() throws {
        let json = releaseJSON(
            dmgURL: "https://example.com/FileFoundry.dmg",
            sumsURL: "https://github.com/junowoz/file-foundry/releases/download/v1.3.0/SHA256SUMS"
        )

        XCTAssertThrowsError(try AppUpdateService.release(from: json))
    }

    func testChecksumParserPicksTheDMGLineFromSHA256SUMS() throws {
        let dmg = String(repeating: "a", count: 64)
        let apk = String(repeating: "b", count: 64)
        let data = Data("\(apk)  FileFoundry-Android.apk\n\(dmg.uppercased())  FileFoundry.dmg\n".utf8)

        XCTAssertEqual(try AppUpdateService.checksum(from: data, for: "FileFoundry.dmg"), dmg)
        XCTAssertEqual(try AppUpdateService.checksum(from: data, for: "FileFoundry-Android.apk"), apk)
    }

    func testChecksumParserRejectsMissingEntryAndMalformedDigest() {
        let other = Data("\(String(repeating: "c", count: 64))  FileFoundry-Android.apk\n".utf8)
        XCTAssertThrowsError(try AppUpdateService.checksum(from: other, for: "FileFoundry.dmg"))

        let short = Data("abc123  FileFoundry.dmg\n".utf8)
        XCTAssertThrowsError(try AppUpdateService.checksum(from: short, for: "FileFoundry.dmg"))
    }

    func testChecksumValidationRejectsMismatchedPackage() throws {
        try withTemporaryDirectory { directory in
            let packageURL = try writeFile(directory, "FileFoundry.dmg", makeData("package"))
            let checksumData = Data(
                "0000000000000000000000000000000000000000000000000000000000000000  FileFoundry.dmg\n".utf8
            )
            let service = AppUpdateService()

            XCTAssertThrowsError(try service.validatePackage(at: packageURL, checksumData: checksumData)) { error in
                guard case AppUpdateError.checksumMismatch = error else { return XCTFail("Unexpected error \(error)") }
            }
        }
    }

    func testChecksumValidationAcceptsMatchingPackage() throws {
        try withTemporaryDirectory { directory in
            let packageURL = try writeFile(directory, "FileFoundry.dmg", makeData("package"))
            let digest = try HashService().sha256(for: packageURL)
            let checksumData = Data("\(digest)  FileFoundry.dmg\n".utf8)

            XCTAssertNoThrow(try AppUpdateService().validatePackage(at: packageURL, checksumData: checksumData))
        }
    }
}
