import Foundation
import XCTest
@testable import FileFoundry

final class AppUpdatesCheckerTests: XCTestCase {
    func testVersionCompareIsNumeric() {
        XCTAssertTrue(AppVersionComparator.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(AppVersionComparator.isNewer("1.9", than: "1.10"))
        XCTAssertEqual(AppVersionComparator.compare("2.0", "2"), .orderedSame)
        XCTAssertTrue(AppVersionComparator.isNewer("1.2.1", than: "1.2"))
        XCTAssertTrue(AppVersionComparator.isNewer("3.0", than: "2.9.9"))
        XCTAssertFalse(AppVersionComparator.isNewer("1.2", than: "1.2.0"))
        XCTAssertEqual(AppVersionComparator.compare("1.2.3-beta", "1.2.3"), .orderedSame)
    }

    func testAppcastPrefersShortVersionStringAndReadsNotes() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>Example</title>
            <item>
              <title>Version 1.3</title>
              <pubDate>Mon, 10 Nov 2026 09:00:00 +0000</pubDate>
              <description><![CDATA[<h2>New</h2><p>Faster &amp; smaller.</p><ul><li>Dark mode</li></ul>]]></description>
              <sparkle:releaseNotesLink>https://example.com/notes/1.3</sparkle:releaseNotesLink>
              <enclosure url="https://example.com/app-1.3.zip" sparkle:version="1303" sparkle:shortVersionString="1.3" length="1" type="application/octet-stream"/>
            </item>
            <item>
              <title>Version 1.2</title>
              <pubDate>Mon, 01 Sep 2026 09:00:00 +0000</pubDate>
              <enclosure url="https://example.com/app-1.2.zip" sparkle:version="1202" sparkle:shortVersionString="1.2" length="1" type="application/octet-stream"/>
            </item>
          </channel>
        </rss>
        """
        let item = SparkleAppcastParser.newestItem(in: Data(xml.utf8))
        XCTAssertEqual(item?.title, "Version 1.3")
        XCTAssertEqual(item?.shortVersion, "1.3")
        XCTAssertEqual(item?.version, "1303")
        XCTAssertEqual(item?.releaseNotes, "New\nFaster & smaller.\nDark mode")
        XCTAssertEqual(item?.releaseNotesURL?.absoluteString, "https://example.com/notes/1.3")
        XCTAssertNotNil(item?.pubDate)
    }

    func testAppcastWithoutShortVersionFallsBackToSparkleVersion() {
        let xml = """
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>Build 2041</title>
              <sparkle:version>2041</sparkle:version>
              <enclosure url="https://example.com/app.zip" sparkle:version="2041" length="1" type="application/octet-stream"/>
            </item>
          </channel>
        </rss>
        """
        let item = SparkleAppcastParser.newestItem(in: Data(xml.utf8))
        XCTAssertNil(item?.shortVersion)
        XCTAssertEqual(item?.version, "2041")
        XCTAssertNil(item?.releaseNotes)
    }

    func testAppcastSkipsBetaChannelItems() {
        let xml = """
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>Beta 2.0</title>
              <sparkle:channel>beta</sparkle:channel>
              <enclosure url="https://example.com/b.zip" sparkle:shortVersionString="2.0" length="1" type="application/octet-stream"/>
            </item>
            <item>
              <title>Stable 1.9</title>
              <enclosure url="https://example.com/s.zip" sparkle:shortVersionString="1.9" length="1" type="application/octet-stream"/>
            </item>
          </channel>
        </rss>
        """
        XCTAssertEqual(SparkleAppcastParser.newestItem(in: Data(xml.utf8))?.shortVersion, "1.9")
    }

    func testHomebrewOutdatedJSONParsesAndDropsBadTokens() throws {
        let json = """
        {"formulae":[],"casks":[
          {"name":["Visual Studio Code"],"token":"visual-studio-code","installed_versions":["1.95.0"],"current_version":"1.96.1"},
          {"name":"Firefox","token":"firefox","installed_versions":"130.0","current_version":"131.0"},
          {"name":["Bad"],"token":"bad token;rm","installed_versions":["1"],"current_version":"2"}
        ]}
        """
        let casks = try HomebrewOutdatedParser.parse(Data(json.utf8))
        XCTAssertEqual(casks.map(\.token), ["visual-studio-code", "firefox"])
        XCTAssertEqual(casks[0].name, "Visual Studio Code")
        XCTAssertEqual(casks[0].installedVersion, "1.95.0")
        XCTAssertEqual(casks[0].currentVersion, "1.96.1")
        XCTAssertEqual(casks[1].installedVersion, "130.0")
    }

    func testTokenValidation() {
        XCTAssertTrue(HomebrewToken.isValid("visual-studio-code"))
        XCTAssertTrue(HomebrewToken.isValid("font-fira-code@beta"))
        XCTAssertTrue(HomebrewToken.isValid("libc++"))
        XCTAssertFalse(HomebrewToken.isValid(""))
        XCTAssertFalse(HomebrewToken.isValid("Firefox"))
        XCTAssertFalse(HomebrewToken.isValid("-force"))
        XCTAssertFalse(HomebrewToken.isValid("a b"))
        XCTAssertFalse(HomebrewToken.isValid("x;rm -rf"))
        XCTAssertFalse(HomebrewToken.isValid("../etc"))
    }

    func testUpgradeRefusesInvalidTokenBeforeRunningAnything() async {
        do {
            try await AppUpdateActions.upgradeCask(token: "bad;token") { _ in }
            XCTFail("Expected invalidToken")
        } catch AppUpdateActionError.invalidToken {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
