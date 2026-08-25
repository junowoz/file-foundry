import XCTest
@testable import DoppelCore

final class ReportExportServiceTests: XCTestCase {
    func testExportsJSONReport() throws {
        try withTemporaryDirectory { directory in
            let file = try ScannedFile(url: writeFile(directory, "a.txt", makeData("same")))
            let group = DuplicateGroup(files: [file], sha256: "hash", verificationLevel: .sha256Match)
            let result = ScanResult(
                selectedFolders: [directory],
                options: .init(),
                scannedFiles: [file],
                skippedFiles: [],
                duplicateGroups: [group]
            )

            let data = try ReportExportService().jsonData(for: result)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            XCTAssertEqual(object?["appVersion"] as? String, AppMetadata.version)
            XCTAssertEqual(object?["schemaVersion"] as? Int, 1)
            XCTAssertEqual(object?["reportType"] as? String, "duplicate-selection-audit")
            XCTAssertNotNil(object?["groups"])
        }
    }

    func testAuditJSONReflectsCurrentSelectionHashesAndKeepPriority() throws {
        try withTemporaryDirectory { directory in
            let favoriteFolder = directory.appendingPathComponent("Music/FAV", isDirectory: true)
            let downloadsFolder = directory.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: favoriteFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)

            let hash = "a-valid-sha256-value"
            let favorite = try ScannedFile(
                url: writeFile(favoriteFolder, "track.wav", makeData("same")),
                sourceFolderURL: directory
            ).with(sha256: hash)
            let download = try ScannedFile(
                url: writeFile(downloadsFolder, "track.wav", makeData("same")),
                sourceFolderURL: directory
            ).with(sha256: hash)
            let group = DuplicateGroup(
                files: [favorite, download],
                sha256: hash,
                verificationLevel: .byteByByteConfirmed,
                recommendedKeepFileID: favorite.id,
                recommendedRemovalFileIDs: [download.id]
            )
            let result = ScanResult(
                selectedFolders: [directory],
                options: ScanOptions(preferredFolderPaths: [favoriteFolder.path]),
                scannedFiles: [favorite, download],
                skippedFiles: [],
                duplicateGroups: [group]
            )

            let data = try ReportExportService().jsonData(
                for: result,
                selectedRemovalFileIDs: [download.id]
            )
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let summary = try XCTUnwrap(object["summary"] as? [String: Any])
            let groups = try XCTUnwrap(object["groups"] as? [[String: Any]])
            let exportedGroup = try XCTUnwrap(groups.first)
            let files = try XCTUnwrap(exportedGroup["files"] as? [[String: Any]])
            let favoriteExport = try XCTUnwrap(files.first { $0["path"] as? String == favorite.path })
            let downloadExport = try XCTUnwrap(files.first { $0["path"] as? String == download.path })

            XCTAssertEqual(summary["selectedKeepFileCount"] as? Int, 1)
            XCTAssertEqual(summary["selectedTrashFileCount"] as? Int, 1)
            XCTAssertEqual(exportedGroup["allFileSHA256Equal"] as? Bool, true)
            XCTAssertEqual(exportedGroup["byteForByteConfirmed"] as? Bool, true)
            XCTAssertEqual(exportedGroup["selectionConsistent"] as? Bool, true)
            XCTAssertEqual(exportedGroup["selectionMatchesHighestKeepPriority"] as? Bool, true)
            XCTAssertEqual(exportedGroup["auditIssues"] as? [String], [])
            XCTAssertEqual(favoriteExport["selectedAction"] as? String, "keep")
            XCTAssertEqual(favoriteExport["matchedKeepPriorityRank"] as? Int, 1)
            XCTAssertEqual(favoriteExport["matchesGroupSHA256"] as? Bool, true)
            XCTAssertEqual(downloadExport["selectedAction"] as? String, "trash")
        }
    }

    func testAuditJSONFlagsManualKeepOutsideHighestPriority() throws {
        try withTemporaryDirectory { directory in
            let favoriteFolder = directory.appendingPathComponent("Favorite", isDirectory: true)
            let otherFolder = directory.appendingPathComponent("Other", isDirectory: true)
            try FileManager.default.createDirectory(at: favoriteFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)

            let hash = "same-hash"
            let favorite = try ScannedFile(url: writeFile(favoriteFolder, "a.wav", makeData("same"))).with(sha256: hash)
            let other = try ScannedFile(url: writeFile(otherFolder, "a.wav", makeData("same"))).with(sha256: hash)
            let group = DuplicateGroup(
                files: [favorite, other],
                sha256: hash,
                verificationLevel: .byteByByteConfirmed,
                recommendedKeepFileID: favorite.id,
                recommendedRemovalFileIDs: [other.id]
            )
            let result = ScanResult(
                selectedFolders: [directory],
                options: ScanOptions(preferredFolderPaths: [favoriteFolder.path]),
                scannedFiles: [favorite, other],
                skippedFiles: [],
                duplicateGroups: [group]
            )

            let data = try ReportExportService().jsonData(for: result, selectedRemovalFileIDs: [favorite.id])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let groups = try XCTUnwrap(object["groups"] as? [[String: Any]])
            let exportedGroup = try XCTUnwrap(groups.first)
            let issues = try XCTUnwrap(exportedGroup["auditIssues"] as? [String])

            XCTAssertEqual(exportedGroup["selectionMatchesHighestKeepPriority"] as? Bool, false)
            XCTAssertTrue(issues.contains("selected-keep-path-is-not-highest-priority-match"))
        }
    }

    func testExportsCSVReportWithEscapedPaths() throws {
        try withTemporaryDirectory { directory in
            let file = try ScannedFile(url: writeFile(directory, "emoji 😀.txt", makeData("same")))
            let group = DuplicateGroup(files: [file], sha256: "hash", verificationLevel: .sha256Match)
            let result = ScanResult(
                selectedFolders: [directory],
                options: .init(),
                scannedFiles: [file],
                skippedFiles: [],
                duplicateGroups: [group]
            )

            let csv = try ReportExportService().csvString(for: result)

            XCTAssertTrue(csv.contains("\"emoji 😀.txt\""))
            XCTAssertTrue(csv.contains("group_id"))
        }
    }
}
