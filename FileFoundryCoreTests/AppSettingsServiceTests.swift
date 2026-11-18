import Foundation
import XCTest
@testable import FileFoundryCore

final class AppSettingsServiceTests: XCTestCase {
    func testLoadsPublishedPredecessorPreferences() throws {
        let suiteName = "FileFoundryCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expected = AppSettings(
            compareMode: .paranoid,
            preferredFolderPaths: ["/Library/Preferred"],
            primaryFolderPaths: ["/Library/Primary"]
        )
        let predecessorKey = ["Dop", "pel.AppSettings"].joined()
        defaults.set(try JSONEncoder().encode(expected), forKey: predecessorKey)

        XCTAssertEqual(AppSettingsService(defaults: defaults).load(), expected)
    }

    func testIgnoresRemovedIncludePackagesKey() throws {
        let suiteName = "FileFoundryCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let json = #"{"compareMode":"safe","includePackages":true,"preferredFolderPaths":["/Library/Preferred"],"primaryFolderPaths":[]}"#
        let key = ["Dop", "pel.AppSettings"].joined()
        defaults.set(Data(json.utf8), forKey: key)

        let loaded = AppSettingsService(defaults: defaults).load()
        XCTAssertEqual(loaded.preferredFolderPaths, ["/Library/Preferred"])
    }
}
