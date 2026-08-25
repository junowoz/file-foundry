import Foundation

public struct ReportExportService: Sendable {
    private let encoder: JSONEncoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func jsonData(
        for result: ScanResult,
        selectedRemovalFileIDs: Set<ScannedFile.ID>? = nil
    ) throws -> Data {
        let selectedIDs = selectedRemovalFileIDs
            ?? Set(result.duplicateGroups.flatMap(\.recommendedRemovalFileIDs))
        return try encoder.encode(AuditReport(result: result, selectedRemovalFileIDs: selectedIDs))
    }

    public func csvString(for result: ScanResult) throws -> String {
        var rows: [[String]] = [[
            "group_id",
            "kept",
            "filename",
            "path",
            "size",
            "sha256",
            "verification",
            "recommendation"
        ]]

        for group in result.duplicateGroups {
            for file in group.files {
                rows.append([
                    group.id.uuidString,
                    file.id == group.recommendedKeepFileID ? "true" : "false",
                    file.filename,
                    file.path,
                    String(file.size),
                    group.sha256,
                    group.verificationLevel.rawValue,
                    group.allowsRemoval
                        ? (group.recommendedRemovalFileIDs.contains(file.id) ? "remove" : "keep")
                        : "review"
                ])
            }
        }

        return rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator: "\n")
    }

    private func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private struct AuditReport: Encodable {
    var schemaVersion: Int
    var reportType: String
    var appVersion: String
    var scanDate: Date
    var exportDate: Date
    var selectedFolders: [String]
    var scanOptions: ScanOptions
    var keepPriority: [KeepPriority]
    var summary: Summary
    var groups: [Group]

    init(result: ScanResult, selectedRemovalFileIDs: Set<ScannedFile.ID>) {
        self.schemaVersion = 1
        self.reportType = "duplicate-selection-audit"
        self.appVersion = result.appVersion
        self.scanDate = result.scanDate
        self.exportDate = Date()
        self.selectedFolders = result.selectedFolders.map(\.path)
        self.scanOptions = result.options
        self.keepPriority = result.options.preferredFolderPaths.enumerated().map {
            KeepPriority(rank: $0.offset + 1, path: $0.element)
        }
        self.groups = result.duplicateGroups.map {
            Group(
                group: $0,
                selectedRemovalFileIDs: selectedRemovalFileIDs,
                preferredFolderPaths: result.options.preferredFolderPaths
            )
        }
        self.summary = Summary(groups: groups)
    }

    struct KeepPriority: Encodable {
        var rank: Int
        var path: String
    }

    struct Summary: Encodable {
        var duplicateGroupCount: Int
        var foundFileCount: Int
        var selectedKeepFileCount: Int
        var selectedTrashFileCount: Int
        var reviewOnlyFileCount: Int
        var byteForByteConfirmedGroupCount: Int
        var selectionIssueCount: Int
        var selectedTrashBytes: Int64

        init(groups: [Group]) {
            self.duplicateGroupCount = groups.count
            self.foundFileCount = groups.reduce(0) { $0 + $1.files.count }
            self.selectedKeepFileCount = groups.reduce(0) { total, group in
                total + group.files.filter { $0.selectedAction == "keep" }.count
            }
            self.selectedTrashFileCount = groups.reduce(0) { total, group in
                total + group.files.filter { $0.selectedAction == "trash" }.count
            }
            self.reviewOnlyFileCount = groups.reduce(0) { total, group in
                total + group.files.filter { $0.selectedAction == "review" }.count
            }
            self.byteForByteConfirmedGroupCount = groups.filter(\.byteForByteConfirmed).count
            self.selectionIssueCount = groups.reduce(0) { $0 + $1.auditIssues.count }
            self.selectedTrashBytes = groups.reduce(0) { total, group in
                total + group.files.reduce(0) { subtotal, file in
                    file.selectedAction == "trash" ? subtotal + file.size : subtotal
                }
            }
        }
    }

    struct Group: Encodable {
        var id: UUID
        var size: Int64
        var groupSHA256: String?
        var verification: VerificationLevel
        var byteForByteConfirmed: Bool
        var allFileSHA256Equal: Bool?
        var selectionConsistent: Bool
        var selectionMatchesHighestKeepPriority: Bool?
        var selectedKeepPaths: [String]
        var selectedTrashPaths: [String]
        var auditIssues: [String]
        var files: [File]

        init(
            group: DuplicateGroup,
            selectedRemovalFileIDs: Set<ScannedFile.ID>,
            preferredFolderPaths: [String]
        ) {
            let groupIDs = Set(group.files.map(\.id))
            let selectedTrashIDs = selectedRemovalFileIDs.intersection(groupIDs)
            let selectedKeepIDs = group.allowsRemoval ? groupIDs.subtracting(selectedTrashIDs) : []
            let groupHash = group.sha256.isEmpty ? nil : group.sha256

            self.id = group.id
            self.size = group.size
            self.groupSHA256 = groupHash
            self.verification = group.verificationLevel
            self.byteForByteConfirmed = group.verificationLevel == .byteByByteConfirmed
            if group.allowsRemoval {
                let hashes = group.files.compactMap(\.sha256)
                self.allFileSHA256Equal = hashes.count == group.files.count
                    && Set(hashes).count == 1
                    && hashes.first == groupHash
            } else {
                self.allFileSHA256Equal = nil
            }
            self.selectionConsistent = !group.allowsRemoval
                || (selectedKeepIDs.count == 1 && selectedTrashIDs.count == group.files.count - 1)
            self.files = group.files.map {
                File(
                    file: $0,
                    group: group,
                    selectedTrashIDs: selectedTrashIDs,
                    preferredFolderPaths: preferredFolderPaths
                )
            }
            self.selectedKeepPaths = files.filter { $0.selectedAction == "keep" }.map(\.path)
            self.selectedTrashPaths = files.filter { $0.selectedAction == "trash" }.map(\.path)

            let matchedRanks = files.compactMap(\.matchedKeepPriorityRank)
            if let highestPriorityRank = matchedRanks.min() {
                self.selectionMatchesHighestKeepPriority = files.contains {
                    $0.selectedAction == "keep" && $0.matchedKeepPriorityRank == highestPriorityRank
                }
            } else {
                self.selectionMatchesHighestKeepPriority = nil
            }

            var issues: [String] = []
            if group.allowsRemoval && !selectionConsistent {
                issues.append("selection-does-not-keep-exactly-one-file")
            }
            if group.allowsRemoval && allFileSHA256Equal != true {
                issues.append("file-sha256-values-do-not-all-match-group")
            }
            if group.allowsRemoval && !byteForByteConfirmed {
                issues.append("group-is-not-byte-for-byte-confirmed")
            }
            if selectionMatchesHighestKeepPriority == false {
                issues.append("selected-keep-path-is-not-highest-priority-match")
            }
            self.auditIssues = issues
        }
    }

    struct File: Encodable {
        var id: UUID
        var filename: String
        var path: String
        var sourceFolderPath: String
        var size: Int64
        var sha256: String?
        var matchesGroupSHA256: Bool?
        var selectedAction: String
        var matchedKeepPriorityRank: Int?
        var matchedKeepPriorityPath: String?
        var recommendationReasons: [RecommendationReason]

        init(
            file: ScannedFile,
            group: DuplicateGroup,
            selectedTrashIDs: Set<ScannedFile.ID>,
            preferredFolderPaths: [String]
        ) {
            self.id = file.id
            self.filename = file.filename
            self.path = file.path
            self.sourceFolderPath = file.sourceFolderPath
            self.size = file.size
            self.sha256 = file.sha256
            self.matchesGroupSHA256 = file.sha256.map { !$0.isEmpty && $0 == group.sha256 }
            self.selectedAction = group.allowsRemoval
                ? (selectedTrashIDs.contains(file.id) ? "trash" : "keep")
                : "review"
            if let match = preferredFolderPaths.enumerated().first(where: {
                Self.contains(filePath: file.path, folderPath: $0.element)
            }) {
                self.matchedKeepPriorityRank = match.offset + 1
                self.matchedKeepPriorityPath = match.element
            } else {
                self.matchedKeepPriorityRank = nil
                self.matchedKeepPriorityPath = nil
            }
            self.recommendationReasons = group.recommendationReasons[file.id] ?? []
        }

        private static func contains(filePath: String, folderPath: String) -> Bool {
            let folder = URL(fileURLWithPath: folderPath).resolvingSymlinksInPath().standardizedFileURL.path
            let file = URL(fileURLWithPath: filePath).resolvingSymlinksInPath().standardizedFileURL.path
            return file == folder || file.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
    }
}
