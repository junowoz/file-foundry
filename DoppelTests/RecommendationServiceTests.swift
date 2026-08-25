import XCTest
@testable import DoppelCore

final class RecommendationServiceTests: XCTestCase {
    func testKeepsIPhonePhotoWithoutCopySuffix() throws {
        try withTemporaryDirectory { directory in
            let original = try ScannedFile(url: writeFile(directory, "IMG_4472.HEIC", makeData("same")))
            let copy = try ScannedFile(url: writeFile(directory, "IMG_4472 2.heic", makeData("same")))
            let group = DuplicateGroup(files: [copy, original], sha256: "hash", verificationLevel: .byteByByteConfirmed)

            let recommendation = RecommendationService().recommendation(for: group, options: .init())

            XCTAssertEqual(recommendation.keepFileID, original.id)
            XCTAssertEqual(recommendation.removalFileIDs, [copy.id])
        }
    }

    func testNeverMarksEveryFileForRemoval() throws {
        try withTemporaryDirectory { directory in
            let only = try ScannedFile(url: writeFile(directory, "only.txt", makeData("same")))
            let group = DuplicateGroup(files: [only], sha256: "hash", verificationLevel: .sha256Match)

            let recommendation = RecommendationService().recommendation(for: group, options: .init())

            XCTAssertEqual(recommendation.keepFileID, only.id)
            XCTAssertTrue(recommendation.removalFileIDs.isEmpty)
        }
    }

    func testHardlinkedFilesAreNotRecommendedForRemoval() throws {
        try withTemporaryDirectory { directory in
            let originalURL = try writeFile(directory, "original.txt", makeData("same"))
            let hardlinkURL = directory.appendingPathComponent("hardlink.txt")
            try FileManager.default.linkItem(at: originalURL, to: hardlinkURL)

            let original = try ScannedFile(url: originalURL)
            let hardlink = try ScannedFile(url: hardlinkURL)
            let group = DuplicateGroup(files: [original, hardlink], sha256: "hash", verificationLevel: .byteByByteConfirmed)

            let recommendation = RecommendationService().recommendation(for: group, options: .init())

            XCTAssertEqual(recommendation.keepFileID, original.id)
            XCTAssertTrue(recommendation.removalFileIDs.isEmpty)
        }
    }

    func testOrderedPreferredSubfolderWinsInsidePreferredLibrary() throws {
        try withTemporaryDirectory { directory in
            let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
            let library = directory.appendingPathComponent("Music_Library", isDirectory: true)
            let wav = library.appendingPathComponent("WAV", isDirectory: true)
            let favorites = library.appendingPathComponent("FAV", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: wav, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: favorites, withIntermediateDirectories: true)

            let downloadCopy = try ScannedFile(url: writeFile(downloads, "track.wav", makeData("same")))
            let wavCopy = try ScannedFile(url: writeFile(wav, "track.wav", makeData("same")))
            let favoriteCopy = try ScannedFile(url: writeFile(favorites, "track.wav", makeData("same")))
            let group = DuplicateGroup(
                files: [downloadCopy, wavCopy, favoriteCopy],
                sha256: "hash",
                verificationLevel: .byteByByteConfirmed
            )
            let options = ScanOptions(preferredFolderPaths: [favorites.path, wav.path, library.path])

            let recommendation = RecommendationService().recommendation(for: group, options: options)

            XCTAssertEqual(recommendation.keepFileID, favoriteCopy.id)
            XCTAssertEqual(recommendation.removalFileIDs, [downloadCopy.id, wavCopy.id])
        }
    }

    func testPreferredFolderMatchesCanonicalPathAlias() throws {
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("DoppelPreferenceTests-\(UUID().uuidString)", isDirectory: true)
        let favorites = root.appendingPathComponent("FAV", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: favorites, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let favoriteCopy = try ScannedFile(url: writeFile(favorites, "track.wav", makeData("same")))
        let downloadCopy = try ScannedFile(url: writeFile(downloads, "track.wav", makeData("same")))
        let group = DuplicateGroup(
            files: [downloadCopy, favoriteCopy],
            sha256: "hash",
            verificationLevel: .byteByByteConfirmed
        )
        let aliasedFavoritePath = favorites.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")

        let recommendation = RecommendationService().recommendation(
            for: group,
            options: ScanOptions(preferredFolderPaths: [aliasedFavoritePath])
        )

        XCTAssertEqual(recommendation.keepFileID, favoriteCopy.id)
        XCTAssertEqual(recommendation.removalFileIDs, [downloadCopy.id])
    }
}
