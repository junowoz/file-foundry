import CryptoKit
import Foundation
import XCTest
@testable import FileFoundry

final class MediaOrganizerCoreTests: XCTestCase {
    func testISODatePreservesEmbeddedWallClockAcrossTimezoneBoundary() throws {
        let components = try XCTUnwrap(MetadataReader().parseISODate("2024-01-31T23:45:12-03:00"))
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 31)
        XCTAssertEqual(components.hour, 23)
    }

    func testSHA256KnownVectorAndEmptyFile() throws {
        try withTemporaryDirectory { root in
            let hello = root.appendingPathComponent("hello.txt")
            let empty = root.appendingPathComponent("empty")
            try Data("hello".utf8).write(to: hello)
            FileManager.default.createFile(atPath: empty.path, contents: Data())
            XCTAssertEqual(try SHA256Hasher(chunkSize: 2).hash(url: hello), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
            XCTAssertEqual(try SHA256Hasher().hash(url: empty), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        }
    }

    func testFilenameParserValidatesCalendar() {
        let parser = FilenameDateParser()
        XCTAssertEqual(parser.parse("IMG_20240229_153000.jpg")?.components.day, 29)
        XCTAssertNil(parser.parse("IMG_20230229_153000.jpg"))
        XCTAssertNil(parser.parse("IMG_20241301.jpg"))
    }

    func testTemplateDefaultInPortuguese() throws {
        let record = fixtureRecord(name: "IMG.jpg", components: DateComponents(year: 2024, month: 7, day: 2))
        let value = try TemplateEngine().resolve(TemplateEngine.defaultTemplate, record: record, sourceFolder: "Origem")
        XCTAssertEqual(value, "2024/07 - Julho")
    }

    func testTemplateRejectsTraversalAndUnknownTokens() {
        XCTAssertThrowsError(try TemplateEngine().validate("../{YYYY}"))
        XCTAssertThrowsError(try TemplateEngine().validate("/{YYYY}"))
        XCTAssertThrowsError(try TemplateEngine().validate("{City}"))
        XCTAssertNoThrow(try TemplateEngine().validate("{MediaType}/{YYYY}/{MM} - {Month}"))
    }

    func testCSVNeutralizesSpreadsheetFormulaPrefixes() {
        XCTAssertEqual(ReportWriter.csvCell("=HYPERLINK(\"https://example.invalid\")"), "\"'=HYPERLINK(\"\"https://example.invalid\"\")\"")
        XCTAssertEqual(ReportWriter.csvCell(" @SUM(1,2)"), "\"' @SUM(1,2)\"")
        XCTAssertEqual(ReportWriter.csvCell("normal, name"), "\"normal, name\"")
    }

    func testPolicyRejectsDestinationRelations() throws {
        try withTemporaryDirectory { root in
            let sourceURL = root.appendingPathComponent("Source", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
            let source = try SourceRoot(url: sourceURL)
            XCTAssertThrowsError(try FileSystemPolicy().validateDisjoint(sources: [source], destination: DestinationRoot(url: sourceURL)))
            XCTAssertThrowsError(try FileSystemPolicy().validateDisjoint(sources: [source], destination: DestinationRoot(url: sourceURL.appendingPathComponent("Output"))))
            XCTAssertNoThrow(try FileSystemPolicy().validateDisjoint(sources: [source], destination: DestinationRoot(url: root.appendingPathComponent("Sibling"))))
        }
    }

    func testPolicyRejectsResolvedPathTraversal() throws {
        try withTemporaryDirectory { root in
            let destination = try DestinationRoot(url: root)
            XCTAssertThrowsError(try FileSystemPolicy().validatedDestination(relativePath: "../escape", in: destination))
            XCTAssertThrowsError(try FileSystemPolicy().validatedDestination(relativePath: "/absolute", in: destination))
            XCTAssertNoThrow(try FileSystemPolicy().validatedDestination(relativePath: "2024/01 - Janeiro/a.jpg", in: destination))
        }
    }

    func testPlannerSeparatesUndatedAndResolvesCaseInsensitiveCollisions() throws {
        let a = fixtureRecord(name: "IMG.JPG", path: "A/IMG.JPG", components: nil)
        let b = fixtureRecord(name: "img.jpg", path: "B/img.jpg", components: nil)
        let summary = ScanSummary(records: [a, b], duplicateGroups: [])
        let source = try SourceRoot(url: URL(fileURLWithPath: "/tmp/source"))
        let adjusted = summary.records.map { record in
            MediaRecord(sourceRootID: source.id, sourceURL: record.sourceURL, relativePath: record.relativePath, filename: record.filename, fileSize: record.fileSize, modificationDate: record.modificationDate, kind: record.kind, captureMoment: record.captureMoment)
        }
        let plan = try ExportPlanner().makePlan(summary: ScanSummary(records: adjusted, duplicateGroups: []), sources: [source], template: TemplateEngine.defaultTemplate)
        XCTAssertEqual(plan.items[0].destinationRelativePath, "Sem Data/Fotos/img.jpg")
        XCTAssertEqual(plan.items[1].destinationRelativePath, "Sem Data/Fotos/IMG (2).JPG")
        XCTAssertEqual(plan.items[1].status, .renamedCollision)
    }

    func testPlannerRoutesAncestorAndReservedNamespaceCollisions() throws {
        let source = try SourceRoot(url: URL(fileURLWithPath: "/tmp/source"))
        let moment = CaptureMoment(components: DateComponents(year: 2024, month: 1, day: 1), source: .embeddedOriginal, confidence: .high)
        let fileAtAncestor = MediaRecord(sourceRootID: source.id, sourceURL: URL(fileURLWithPath: "/tmp/source/Sidecars"), relativePath: "Sidecars", filename: "Sidecars", fileSize: 1, modificationDate: nil, kind: .other, captureMoment: moment)
        let child = MediaRecord(sourceRootID: source.id, sourceURL: URL(fileURLWithPath: "/tmp/source/z.json"), relativePath: "z.json", filename: "z.json", fileSize: 1, modificationDate: nil, kind: .sidecar, captureMoment: moment)
        let reserved = MediaRecord(sourceRootID: source.id, sourceURL: URL(fileURLWithPath: "/tmp/source/photo.jpg"), relativePath: "photo.jpg", filename: "photo.jpg", fileSize: 1, modificationDate: nil, kind: .photo, captureMoment: moment)

        let plan = try ExportPlanner().makePlan(summary: ScanSummary(records: [fileAtAncestor, child, reserved], duplicateGroups: []), sources: [source], template: "Relatórios/{YYYY}")
        XCTAssertTrue(plan.items.allSatisfy { !$0.destinationRelativePath.lowercased().hasPrefix("relatórios/") })
        XCTAssertTrue(plan.items.contains { $0.destinationRelativePath.hasPrefix("Conflitos de Estrutura/") })
        let normalized = plan.items.map { $0.destinationRelativePath.lowercased() }
        for path in normalized {
            XCTAssertFalse(normalized.contains { $0 != path && ($0.hasPrefix(path + "/") || path.hasPrefix($0 + "/")) })
        }
    }

    func testScanSummaryMarksInaccessibleRecordsIncomplete() {
        let record = MediaRecord(sourceRootID: UUID(), sourceURL: URL(fileURLWithPath: "/tmp/unreadable"), relativePath: "unreadable", filename: "unreadable", fileSize: 0, modificationDate: nil, kind: .other, captureMoment: nil, disposition: .inaccessible, note: "denied")
        let summary = ScanSummary(records: [record], duplicateGroups: [])
        XCTAssertFalse(summary.isComplete)
        XCTAssertEqual(summary.enumerationErrorCount, 1)
    }

    func testScannerDoesNotFollowSymlinkAndFindsExactDuplicates() async throws {
        try await withTemporaryDirectoryAsync { root in
            let sourceURL = root.appendingPathComponent("Source", isDirectory: true)
            let outside = root.appendingPathComponent("Outside", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceURL.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let bytes = Data("identical-media".utf8)
            try bytes.write(to: sourceURL.appendingPathComponent("IMG_20240101.jpg"))
            try bytes.write(to: sourceURL.appendingPathComponent("nested/copy.jpg"))
            try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.jpg"))
            try FileManager.default.createSymbolicLink(at: sourceURL.appendingPathComponent("escape"), withDestinationURL: outside)

            let source = try SourceRoot(url: sourceURL)
            let result = try await MediaScanner().scan(sources: [source])
            XCTAssertEqual(result.duplicateGroups.count, 1)
            XCTAssertEqual(result.duplicateGroups[0].duplicateIDs.count, 1)
            XCTAssertTrue(result.records.contains { $0.disposition == .ignoredSymbolicLink })
            XCTAssertFalse(result.records.contains { $0.filename == "secret.jpg" })
        }
    }

    func testEndToEndExportPreservesSourceAndVerifiesEveryCopy() async throws {
        try await withTemporaryDirectoryAsync { root in
            let sourceURL = root.appendingPathComponent("Source", isDirectory: true)
            let destinationURL = root.appendingPathComponent("Destination", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceURL.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            try Data("photo-one".utf8).write(to: sourceURL.appendingPathComponent("IMG_20240115.jpg"))
            try Data("photo-two".utf8).write(to: sourceURL.appendingPathComponent("nested/IMG_20240220.jpg"))
            try Data("no date".utf8).write(to: sourceURL.appendingPathComponent("unknown.jpg"))
            let before = try treeFingerprint(sourceURL)

            let source = try SourceRoot(url: sourceURL)
            let summary = try await MediaScanner().scan(sources: [source])
            let plan = try ExportPlanner().makePlan(summary: summary, sources: [source], template: TemplateEngine.defaultTemplate)
            let (output, manifest) = try await VerifiedCopyEngine().export(plan: plan, sources: [source], destinationParent: DestinationRoot(url: destinationURL))

            XCTAssertEqual(try treeFingerprint(sourceURL), before)
            XCTAssertEqual(manifest.records.count, 3)
            XCTAssertTrue(manifest.records.allSatisfy { $0.status == .committedVerified && $0.sha256 != nil })
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("2024/01 - Janeiro/IMG_20240115.jpg").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("Sem Data/Fotos/unknown.jpg").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("Relatórios/manifest.json").path))
        }
    }

    private func fixtureRecord(name: String, path: String? = nil, components: DateComponents?) -> MediaRecord {
        MediaRecord(sourceRootID: UUID(), sourceURL: URL(fileURLWithPath: "/tmp/\(name)"), relativePath: path ?? name, filename: name, fileSize: 10, modificationDate: nil, kind: .photo, captureMoment: components.map { CaptureMoment(components: $0, source: .embeddedOriginal, confidence: .high) })
    }

    private func treeFingerprint(_ root: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            if (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let relative = String(url.path.dropFirst(root.path.count + 1))
                result[relative] = try SHA256Hasher().hash(url: url)
            }
        }
        return result
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaOrganizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func withTemporaryDirectoryAsync(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaOrganizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
}
