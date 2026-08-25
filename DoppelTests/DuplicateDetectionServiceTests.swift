import XCTest
@testable import DoppelCore

final class DuplicateDetectionServiceTests: XCTestCase {
    func testDetectsByteConfirmedDuplicates() async throws {
        try await withTemporaryDirectory { directory in
            _ = try writeFile(directory, "IMG_4472.HEIC", makeData("photo bytes"))
            _ = try writeFile(directory, "IMG_4472 2.heic", makeData("photo bytes"))
            _ = try writeFile(directory, "different.txt", makeData("other bytes"))

            let result = try await DuplicateDetectionService().scan(
                folders: [directory],
                options: ScanOptions(compareMode: .safe)
            )

            XCTAssertEqual(result.duplicateGroups.count, 1)
            XCTAssertEqual(result.duplicateGroups[0].verificationLevel, .byteByByteConfirmed)
            XCTAssertEqual(result.duplicateGroups[0].files.count, 2)
        }
    }

    func testSameSizedDifferentFilesAreNotDuplicates() async throws {
        try await withTemporaryDirectory { directory in
            _ = try writeFile(directory, "one.txt", makeData("abc123"))
            _ = try writeFile(directory, "two.txt", makeData("xyz789"))

            let result = try await DuplicateDetectionService().scan(
                folders: [directory],
                options: ScanOptions(compareMode: .safe)
            )

            XCTAssertTrue(result.duplicateGroups.isEmpty)
        }
    }

    func testScannerSkipsPackagesByDefault() async throws {
        try await withTemporaryDirectory { directory in
            let package = directory.appendingPathComponent("Example.app", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            _ = try writeFile(package, "duplicate.txt", makeData("same"))
            _ = try writeFile(directory, "duplicate.txt", makeData("same"))

            let result = try await DuplicateDetectionService().scan(
                folders: [directory],
                options: ScanOptions(ignorePackages: true)
            )

            XCTAssertTrue(result.duplicateGroups.isEmpty)
        }
    }

    func testFileRemovedDuringScanIsSkipped() async throws {
        try await withTemporaryDirectory { directory in
            let disappearing = try writeFile(directory, "gone.txt", makeData("same"))
            _ = try writeFile(directory, "still.txt", makeData("same"))

            let scanner = FileScannerService(fileDidIndex: { file in
                if file.filename == disappearing.lastPathComponent {
                    try? FileManager.default.removeItem(at: disappearing)
                }
            })

            let result = try await DuplicateDetectionService(scanner: scanner).scan(
                folders: [directory],
                options: ScanOptions(compareMode: .safe)
            )

            XCTAssertTrue(result.duplicateGroups.isEmpty)
            XCTAssertEqual(result.skippedFiles.count, 1)
        }
    }

    func testBetweenFoldersOnlyReturnsGroupsSpanningSelectedRoots() async throws {
        try await withTemporaryDirectory { directory in
            let firstRoot = directory.appendingPathComponent("First", isDirectory: true)
            let secondRoot = directory.appendingPathComponent("Second", isDirectory: true)
            try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)

            _ = try writeFile(firstRoot, "internal-a.txt", makeData("internal duplicate"))
            _ = try writeFile(firstRoot, "internal-b.txt", makeData("internal duplicate"))
            _ = try writeFile(firstRoot, "cross-a.txt", makeData("cross duplicate"))
            _ = try writeFile(secondRoot, "cross-b.txt", makeData("cross duplicate"))

            let result = try await DuplicateDetectionService().scan(
                folders: [firstRoot, secondRoot],
                options: ScanOptions(compareMode: .safe, searchScope: .betweenFolders)
            )

            XCTAssertEqual(result.duplicateGroups.count, 1)
            XCTAssertEqual(Set(result.duplicateGroups[0].files.map(\.sourceFolderPath)).count, 2)
            XCTAssertEqual(Set(result.duplicateGroups[0].files.map(\.filename)), ["cross-a.txt", "cross-b.txt"])
        }
    }

    func testWithinFoldersSplitsGroupsBySelectedRoot() async throws {
        try await withTemporaryDirectory { directory in
            let firstRoot = directory.appendingPathComponent("First", isDirectory: true)
            let secondRoot = directory.appendingPathComponent("Second", isDirectory: true)
            try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)

            _ = try writeFile(firstRoot, "one.txt", makeData("same content"))
            _ = try writeFile(firstRoot, "two.txt", makeData("same content"))
            _ = try writeFile(secondRoot, "three.txt", makeData("same content"))
            _ = try writeFile(secondRoot, "four.txt", makeData("same content"))

            let result = try await DuplicateDetectionService().scan(
                folders: [firstRoot, secondRoot],
                options: ScanOptions(compareMode: .safe, searchScope: .withinFolders)
            )

            XCTAssertEqual(result.duplicateGroups.count, 2)
            XCTAssertTrue(result.duplicateGroups.allSatisfy { Set($0.files.map(\.sourceFolderPath)).count == 1 })
        }
    }

    func testMetadataCanMatchFilenameWithoutExtension() async throws {
        try await withTemporaryDirectory { directory in
            let firstRoot = directory.appendingPathComponent("First", isDirectory: true)
            let secondRoot = directory.appendingPathComponent("Second", isDirectory: true)
            try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
            _ = try writeFile(firstRoot, "Summer Mix.wav", makeData("first encoding"))
            _ = try writeFile(secondRoot, "summer mix.mp3", makeData("different encoding"))

            let result = try await DuplicateDetectionService().scan(
                folders: [firstRoot, secondRoot],
                options: ScanOptions(
                    matchMode: .metadata,
                    searchScope: .betweenFolders,
                    metadataCriteria: MetadataMatchCriteria(filename: true, fileExtension: false)
                )
            )

            XCTAssertEqual(result.duplicateGroups.count, 1)
            XCTAssertEqual(result.duplicateGroups[0].verificationLevel, .metadataMatch)
            XCTAssertFalse(result.duplicateGroups[0].allowsRemoval)
            XCTAssertTrue(result.duplicateGroups[0].recommendedRemovalFileIDs.isEmpty)
            XCTAssertEqual(result.duplicateGroups[0].totalLogicalWastedBytes, 0)
        }
    }

    func testMetadataExtensionCriterionCanExcludeDifferentFormats() async throws {
        try await withTemporaryDirectory { directory in
            _ = try writeFile(directory, "track.wav", makeData("first encoding"))
            _ = try writeFile(directory, "track.mp3", makeData("different encoding"))

            let result = try await DuplicateDetectionService().scan(
                folders: [directory],
                options: ScanOptions(
                    matchMode: .metadata,
                    metadataCriteria: MetadataMatchCriteria(filename: true, fileExtension: true)
                )
            )

            XCTAssertTrue(result.duplicateGroups.isEmpty)
        }
    }

    func testMetadataCanMatchMediaDuration() async throws {
        try await withTemporaryDirectory { directory in
            _ = try writeFile(directory, "first.wav", makeWaveData(sampleByte: 0x20))
            _ = try writeFile(directory, "second.wav", makeWaveData(sampleByte: 0x80))

            let result = try await DuplicateDetectionService().scan(
                folders: [directory],
                options: ScanOptions(
                    matchMode: .metadata,
                    metadataCriteria: MetadataMatchCriteria(filename: false, duration: true)
                )
            )

            XCTAssertEqual(result.duplicateGroups.count, 1)
            XCTAssertEqual(result.duplicateGroups[0].files.count, 2)
            XCTAssertTrue(result.duplicateGroups[0].files.allSatisfy { $0.mediaDurationSeconds != nil })
        }
    }

    func testMetadataFileKindCanExcludeDifferentMediaKinds() async throws {
        try await withTemporaryDirectory { directory in
            _ = try writeFile(directory, "clip.wav", makeWaveData(sampleByte: 0x20))
            _ = try writeFile(directory, "clip.mp4", makeData("not actual video data"))

            let result = try await DuplicateDetectionService().scan(
                folders: [directory],
                options: ScanOptions(
                    matchMode: .metadata,
                    metadataCriteria: MetadataMatchCriteria(filename: true, fileKind: true)
                )
            )

            XCTAssertTrue(result.duplicateGroups.isEmpty)
        }
    }
}
