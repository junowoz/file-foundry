import XCTest
@testable import FileFoundryCore

@MainActor
final class MainViewModelTests: XCTestCase {
    func testSelectingCurrentKeepFileForRemovalSwapsKeepFile() throws {
        try withTemporaryDirectory { directory in
            let first = try ScannedFile(url: writeFile(directory, "first.wav", makeData("same")))
            let second = try ScannedFile(url: writeFile(directory, "second.wav", makeData("same")))
            let group = DuplicateGroup(
                files: [first, second],
                sha256: "hash",
                verificationLevel: .byteByByteConfirmed,
                recommendedKeepFileID: first.id,
                recommendedRemovalFileIDs: [second.id]
            )
            let viewModel = makeViewModel()
            viewModel.scanResult = scanResult(group: group)
            viewModel.selectedRemovalFileIDs = [second.id]

            viewModel.setRemovalSelection(true, file: first, group: group)

            XCTAssertEqual(viewModel.selectedRemovalFileIDs, [first.id])
            XCTAssertEqual(viewModel.duplicateGroups[0].recommendedKeepFileID, second.id)
            XCTAssertEqual(viewModel.duplicateGroups[0].recommendedRemovalFileIDs, [first.id])
        }
    }

    func testMarkFileToKeepSelectsOtherFilesForRemoval() throws {
        try withTemporaryDirectory { directory in
            let first = try ScannedFile(url: writeFile(directory, "first.wav", makeData("same")))
            let second = try ScannedFile(url: writeFile(directory, "second.wav", makeData("same")))
            let third = try ScannedFile(url: writeFile(directory, "third.wav", makeData("same")))
            let group = DuplicateGroup(
                files: [first, second, third],
                sha256: "hash",
                verificationLevel: .byteByByteConfirmed,
                recommendedKeepFileID: first.id,
                recommendedRemovalFileIDs: [second.id, third.id]
            )
            let viewModel = makeViewModel()
            viewModel.scanResult = scanResult(group: group)
            viewModel.selectedRemovalFileIDs = [second.id, third.id]

            viewModel.markFileToKeep(second, in: group)

            XCTAssertEqual(viewModel.selectedRemovalFileIDs, [first.id, third.id])
            XCTAssertEqual(viewModel.duplicateGroups[0].recommendedKeepFileID, second.id)
            XCTAssertEqual(viewModel.reviewState(for: second, in: viewModel.duplicateGroups[0]), .keep)
            XCTAssertEqual(viewModel.reviewState(for: first, in: viewModel.duplicateGroups[0]), .remove)
        }
    }

    func testMetadataMatchCannotBeSelectedForRemoval() throws {
        try withTemporaryDirectory { directory in
            let first = try ScannedFile(url: writeFile(directory, "track.wav", makeData("first")))
            let second = try ScannedFile(url: writeFile(directory, "track.mp3", makeData("second")))
            let group = DuplicateGroup(
                files: [first, second],
                sha256: "",
                verificationLevel: .metadataMatch
            )
            let viewModel = makeViewModel()
            viewModel.scanResult = scanResult(group: group)

            viewModel.setRemovalSelection(true, file: second, group: group)

            XCTAssertTrue(viewModel.selectedRemovalFileIDs.isEmpty)
            XCTAssertFalse(viewModel.canMoveSelectedFiles)
            XCTAssertEqual(viewModel.statusMessage, "Run Exact matching before moving metadata matches to Trash.")
        }
    }

    func testPreferredFolderRuleReplansEveryExactGroup() throws {
        try withTemporaryDirectory { directory in
            let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
            let favorites = directory.appendingPathComponent("Favorites", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: favorites, withIntermediateDirectories: true)

            let downloadOne = try ScannedFile(url: writeFile(downloads, "one.wav", makeData("one")))
            let favoriteOne = try ScannedFile(url: writeFile(favorites, "one.wav", makeData("one")))
            let downloadTwo = try ScannedFile(url: writeFile(downloads, "two.wav", makeData("two")))
            let favoriteTwo = try ScannedFile(url: writeFile(favorites, "two.wav", makeData("two")))
            let groups = [
                DuplicateGroup(files: [downloadOne, favoriteOne], sha256: "one", verificationLevel: .byteByByteConfirmed),
                DuplicateGroup(files: [downloadTwo, favoriteTwo], sha256: "two", verificationLevel: .byteByByteConfirmed)
            ]
            let viewModel = makeViewModel()
            viewModel.scanResult = ScanResult(
                selectedFolders: [directory],
                options: ScanOptions(),
                scannedFiles: groups.flatMap(\.files),
                skippedFiles: [],
                duplicateGroups: groups
            )

            viewModel.addPreferredFolder(favorites)

            XCTAssertEqual(Set(viewModel.duplicateGroups.compactMap(\.recommendedKeepFileID)), [favoriteOne.id, favoriteTwo.id])
            XCTAssertEqual(viewModel.selectedRemovalFileIDs, [downloadOne.id, downloadTwo.id])
            XCTAssertEqual(viewModel.statusMessage, "Keep priority applied to all groups.")
        }
    }

    func testPreferredFolderOrderPersists() throws {
        try withTemporaryDirectory { directory in
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            let service = AppSettingsService(defaults: defaults)
            let viewModel = MainViewModel(appSettingsService: service)

            viewModel.addPreferredFolder(directory)

            XCTAssertEqual(service.load().preferredFolderPaths, [directory.standardizedFileURL.path])
        }
    }

    func testExactModeAlwaysStartsWithByteComparison() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let viewModel = MainViewModel(
            options: ScanOptions(compareMode: .fast, matchMode: .exactContent),
            appSettingsService: AppSettingsService(defaults: defaults)
        )

        XCTAssertEqual(viewModel.options.compareMode, .safe)
    }

    func testExportJSONWritesCurrentUISelectionToDisk() throws {
        try withTemporaryDirectory { directory in
            let hash = "same-hash"
            let first = try ScannedFile(url: writeFile(directory, "first.wav", makeData("same"))).with(sha256: hash)
            let second = try ScannedFile(url: writeFile(directory, "second.wav", makeData("same"))).with(sha256: hash)
            let group = DuplicateGroup(
                files: [first, second],
                sha256: hash,
                verificationLevel: .byteByByteConfirmed,
                recommendedKeepFileID: first.id,
                recommendedRemovalFileIDs: [second.id]
            )
            let viewModel = makeViewModel()
            viewModel.scanResult = scanResult(group: group)
            viewModel.selectedRemovalFileIDs = [first.id]
            let reportURL = directory.appendingPathComponent("audit.json")

            try viewModel.exportJSON(to: reportURL)

            let data = try Data(contentsOf: reportURL)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let groups = try XCTUnwrap(object["groups"] as? [[String: Any]])
            let files = try XCTUnwrap(groups.first?["files"] as? [[String: Any]])
            let firstExport = try XCTUnwrap(files.first { $0["path"] as? String == first.path })
            let secondExport = try XCTUnwrap(files.first { $0["path"] as? String == second.path })

            XCTAssertEqual(firstExport["selectedAction"] as? String, "trash")
            XCTAssertEqual(secondExport["selectedAction"] as? String, "keep")
            XCTAssertEqual(viewModel.statusMessage, "Exported audit JSON")
        }
    }

    private func makeViewModel() -> MainViewModel {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return MainViewModel(appSettingsService: AppSettingsService(defaults: defaults))
    }

    private func scanResult(group: DuplicateGroup) -> ScanResult {
        ScanResult(
            selectedFolders: [],
            options: ScanOptions(),
            scannedFiles: group.files,
            skippedFiles: [],
            duplicateGroups: [group]
        )
    }
}
