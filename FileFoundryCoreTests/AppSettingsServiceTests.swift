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
            includePackages: true,
            preferredFolderPaths: ["/Library/Preferred"],
            primaryFolderPaths: ["/Library/Primary"]
        )
        let predecessorKey = ["Dop", "pel.AppSettings"].joined()
        defaults.set(try JSONEncoder().encode(expected), forKey: predecessorKey)

        XCTAssertEqual(AppSettingsService(defaults: defaults).load(), expected)
    }
}
