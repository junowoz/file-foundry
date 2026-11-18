import Combine
import Foundation

public enum FileReviewState: Equatable, Sendable {
    case keep
    case remove
    case needsReview
}

@MainActor
public final class MainViewModel: ObservableObject {
    @Published public var folders: [URL]
    @Published public var options: ScanOptions
    @Published public var scanState: ScanState
    @Published public var scanResult: ScanResult?
    @Published public var selectedGroupID: DuplicateGroup.ID?
    @Published public var selectedFileID: ScannedFile.ID?
    @Published public var selectedRemovalFileIDs: Set<ScannedFile.ID>
    @Published public var statusMessage: String
    @Published public var actionLogs: [ActionLog]
    @Published public var currentFileDescription: String

    private let duplicateDetectionService: DuplicateDetectionService
    private let fileActionService: FileActionService
    private let reportExportService: ReportExportService
    private let recommendationService: RecommendationService
    private let appSettingsService: AppSettingsService
    private var scanTask: Task<Void, Never>?

    public init(
        folders: [URL] = [],
        options: ScanOptions = ScanOptions(),
        duplicateDetectionService: DuplicateDetectionService = DuplicateDetectionService(),
        fileActionService: FileActionService = FileActionService(),
        reportExportService: ReportExportService = ReportExportService(),
        recommendationService: RecommendationService = RecommendationService(),
        appSettingsService: AppSettingsService = AppSettingsService()
    ) {
        var initialOptions = options
        let savedSettings = appSettingsService.load()
        if initialOptions.preferredFolderPaths.isEmpty {
            initialOptions.preferredFolderPaths = savedSettings.preferredFolderPaths.map(Self.canonicalFolderPath)
        } else {
            initialOptions.preferredFolderPaths = initialOptions.preferredFolderPaths.map(Self.canonicalFolderPath)
        }
        // Packages (.app, .photoslibrary, …) are always single items and are skipped.
        initialOptions.ignorePackages = true
        initialOptions.compareMode = .safe
        self.folders = folders
        self.options = initialOptions
        self.scanState = .idle
        self.scanResult = nil
        self.selectedGroupID = nil
        self.selectedFileID = nil
        self.selectedRemovalFileIDs = []
        self.statusMessage = "Ready"
        self.actionLogs = []
        self.currentFileDescription = ""
        self.duplicateDetectionService = duplicateDetectionService
        self.fileActionService = fileActionService
        self.reportExportService = reportExportService
        self.recommendationService = recommendationService
        self.appSettingsService = appSettingsService
    }

    public var duplicateGroups: [DuplicateGroup] {
        scanResult?.duplicateGroups ?? []
    }

    public var selectedGroup: DuplicateGroup? {
        duplicateGroups.first { $0.id == selectedGroupID }
    }

    public var selectedFile: ScannedFile? {
        if let selectedFileID {
            if let hit = selectedGroup?.files.first(where: { $0.id == selectedFileID }) { return hit }
            for group in duplicateGroups {
                if let hit = group.files.first(where: { $0.id == selectedFileID }) { return hit }
            }
            return nil
        }
        return selectedGroup?.files.first
    }

    public var totalScannedFiles: Int {
        scanResult?.scannedFiles.count ?? 0
    }

    public var totalDuplicateGroups: Int {
        scanResult?.duplicateGroups.count ?? 0
    }

    public var totalRemovableFiles: Int {
        selectedRemovalFileIDs.count
    }

    public var potentialSavings: Int64 {
        guard let result = scanResult else { return 0 }
        return result.duplicateGroups.reduce(Int64(0)) { total, group in
            total + selectedSavings(in: group)
        }
    }

    public var canMoveSelectedFiles: Bool {
        !selectedRemovalFileIDs.isEmpty && scanState != .movingToTrash
    }

    public var canStartScan: Bool {
        guard scanState != .indexing, !folders.isEmpty else { return false }
        if options.searchScope == .betweenFolders && folders.count < 2 { return false }
        if options.matchMode == .metadata && !options.metadataCriteria.hasSelection { return false }
        return true
    }

    public func addFolder(_ folder: URL) {
        guard !folders.contains(folder) else { return }
        folders.append(folder)
        statusMessage = "Folder added"
    }

    public func removeSelectedFolder(_ folder: URL?) {
        guard let folder else { return }
        folders.removeAll { $0 == folder }
        statusMessage = "Folder removed"
    }

    public func clearFolders() {
        folders.removeAll()
        scanResult = nil
        selectedGroupID = nil
        selectedFileID = nil
        selectedRemovalFileIDs.removeAll()
        statusMessage = "Cleared"
    }

    public func addPreferredFolder(_ folder: URL) {
        let path = Self.canonicalFolderPath(folder.path)
        guard !options.preferredFolderPaths.contains(path) else {
            statusMessage = "This keep location is already in the priority list."
            return
        }
        options.preferredFolderPaths.append(path)
        applyKeepRules()
    }

    public func removePreferredFolder(at index: Int) {
        guard options.preferredFolderPaths.indices.contains(index) else { return }
        options.preferredFolderPaths.remove(at: index)
        applyKeepRules()
    }

    public func movePreferredFolder(from index: Int, by offset: Int) {
        let destination = index + offset
        guard options.preferredFolderPaths.indices.contains(index),
              options.preferredFolderPaths.indices.contains(destination)
        else { return }
        options.preferredFolderPaths.swapAt(index, destination)
        applyKeepRules()
    }

    public func applyKeepRules() {
        savePreferredFolders()
        guard var result = scanResult else {
            statusMessage = options.preferredFolderPaths.isEmpty ? "Keep priority cleared." : "Keep priority updated."
            return
        }

        result.options = options
        result.duplicateGroups = result.duplicateGroups.map { group in
            guard group.allowsRemoval else { return group }
            let recommendation = recommendationService.recommendation(for: group, options: options)
            return DuplicateGroup(
                id: group.id,
                files: group.files,
                sha256: group.sha256,
                verificationLevel: group.verificationLevel,
                recommendedKeepFileID: recommendation.keepFileID,
                recommendedRemovalFileIDs: recommendation.removalFileIDs,
                recommendationReasons: recommendation.reasons
            )
        }
        scanResult = result
        selectedRemovalFileIDs = Set(result.duplicateGroups.flatMap(\.recommendedRemovalFileIDs))
        statusMessage = options.preferredFolderPaths.isEmpty ? "Keep priority cleared." : "Keep priority applied to all groups."
    }

    private func savePreferredFolders() {
        var settings = appSettingsService.load()
        settings.preferredFolderPaths = options.preferredFolderPaths
        try? appSettingsService.save(settings)
    }

    private static func canonicalFolderPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public func startScan() {
        guard !folders.isEmpty else {
            statusMessage = "Add a folder first"
            return
        }
        guard options.searchScope != .betweenFolders || folders.count > 1 else {
            statusMessage = "Add at least two folders for Between Folders."
            return
        }
        guard options.matchMode != .metadata || options.metadataCriteria.hasSelection else {
            statusMessage = "Pick at least one detail to match by."
            return
        }
        if options.matchMode == .exactContent {
            options.compareMode = .safe
        }
        scanTask?.cancel()
        scanState = .indexing
        statusMessage = "Scanning"
        scanResult = nil
        selectedGroupID = nil
        selectedFileID = nil
        selectedRemovalFileIDs.removeAll()

        let folders = folders
        let options = options
        let service = duplicateDetectionService

        scanTask = Task(priority: .userInitiated) { [weak self, folders, options, service] in
            do {
                let result = try await service.scan(folders: folders, options: options)
                self?.applyScanResult(result)
            } catch is CancellationError {
                self?.scanState = .cancelled
                self?.statusMessage = "Cancelled"
            } catch {
                self?.scanState = .error
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    public func pauseScan() {
        guard scanState != .finished else { return }
        scanState = .paused
        statusMessage = "Paused"
    }

    public func resumeScan() {
        guard scanState == .paused else { return }
        scanState = .indexing
        statusMessage = "Resumed"
    }

    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanState = .cancelled
        statusMessage = "Cancelled"
    }

    public func select(group: DuplicateGroup) {
        selectedGroupID = group.id
        selectedFileID = group.files.first?.id
    }

    public func select(file: ScannedFile, in group: DuplicateGroup) {
        selectedGroupID = group.id
        selectedFileID = file.id
        currentFileDescription = file.filename
    }

    public func isSelectedForRemoval(_ file: ScannedFile) -> Bool {
        selectedRemovalFileIDs.contains(file.id)
    }

    public func selectedRemovalIDs(in group: DuplicateGroup) -> Set<ScannedFile.ID> {
        selectedRemovalFileIDs.intersection(Set(group.files.map(\.id)))
    }

    public func selectedRemovalCount(in group: DuplicateGroup) -> Int {
        selectedRemovalIDs(in: group).count
    }

    public func selectedSavings(in group: DuplicateGroup) -> Int64 {
        let removalIDs = selectedRemovalIDs(in: group)
        return group.files.reduce(Int64(0)) { total, file in
            removalIDs.contains(file.id) ? total + file.size : total
        }
    }

    public func reviewState(for file: ScannedFile, in group: DuplicateGroup) -> FileReviewState {
        if isSelectedForRemoval(file) {
            return .remove
        }
        if selectedRemovalCount(in: group) > 0 || file.id == group.recommendedKeepFileID {
            return .keep
        }
        return .needsReview
    }

    public func setRemovalSelection(_ selected: Bool, file: ScannedFile, group: DuplicateGroup) {
        guard group.allowsRemoval else {
            statusMessage = "Switch to Identical Content before moving these matches to Trash."
            return
        }
        let groupIDs = Set(group.files.map(\.id))
        guard groupIDs.contains(file.id) else { return }

        var selectedInGroup = selectedRemovalIDs(in: group)
        if selected {
            selectedInGroup.insert(file.id)
            if selectedInGroup.count == group.files.count {
                guard let fallbackKeepFile = group.files.first(where: { $0.id != file.id }) else {
                    statusMessage = "At least one file is always kept."
                    return
                }
                selectedInGroup.remove(fallbackKeepFile.id)
                statusMessage = "Keeping \(fallbackKeepFile.filename)."
            } else {
                statusMessage = "Marked \(file.filename) for Trash."
            }
        } else {
            selectedInGroup.remove(file.id)
            statusMessage = "Keeping \(file.filename)."
        }

        applyRemovalSelection(selectedInGroup, in: group)
    }

    public func toggleRemovalSelection(for file: ScannedFile, in group: DuplicateGroup) {
        setRemovalSelection(!isSelectedForRemoval(file), file: file, group: group)
    }

    public func markFileToKeep(_ file: ScannedFile, in group: DuplicateGroup) {
        guard group.allowsRemoval else {
            statusMessage = "Matching Details only finds candidates. Switch to Identical Content to verify them."
            return
        }
        let groupIDs = Set(group.files.map(\.id))
        guard groupIDs.contains(file.id), group.files.count > 1 else {
            statusMessage = "At least one file is always kept."
            return
        }

        applyRemovalSelection(groupIDs.subtracting([file.id]), in: group)
        statusMessage = "Keeping \(file.filename)."
    }

    public func moveSelectedToTrash() async {
        guard let result = scanResult else { return }
        scanState = .movingToTrash
        statusMessage = "Selected files will be moved to Trash."

        let selectedIDs = selectedRemovalFileIDs
        let options = result.options
        let actionService = fileActionService
        var logs: [ActionLog] = []
        var movedIDs: Set<ScannedFile.ID> = []

        do {
            // Re-hashing and byte comparison can read gigabytes: keep it off the main actor.
            let outcome = try await Task.detached(priority: .userInitiated) { () throws -> ([ActionLog], Set<ScannedFile.ID>) in
                var logs: [ActionLog] = []
                var movedIDs: Set<ScannedFile.ID> = []
                for group in result.duplicateGroups {
                    let groupIDs = Set(group.files.map(\.id))
                    let removalIDs = selectedIDs.intersection(groupIDs)
                    guard !removalIDs.isEmpty else { continue }
                    guard let keepID = group.files.first(where: { !removalIDs.contains($0.id) })?.id else { continue }

                    let log = try actionService.moveSelectedToTrash(
                        group: group,
                        keepFileID: keepID,
                        removalFileIDs: removalIDs,
                        compareMode: options.compareMode
                    )
                    logs.append(log)
                    movedIDs.formUnion(removalIDs)
                }
                return (logs, movedIDs)
            }.value
            logs = outcome.0
            movedIDs = outcome.1

            actionLogs.append(contentsOf: logs)
            selectedRemovalFileIDs.subtract(movedIDs)
            removeMovedFilesFromResult(movedIDs)
            scanState = .finished
            statusMessage = "Moved \(movedIDs.count) file(s) to Trash."
        } catch {
            scanState = .error
            statusMessage = error.localizedDescription
        }
    }

    public func exportJSON(to url: URL) throws {
        guard let result = scanResult else { return }
        let data = try reportExportService.jsonData(
            for: result,
            selectedRemovalFileIDs: selectedRemovalFileIDs
        )
        try data.write(to: url, options: .atomic)
        statusMessage = "Exported audit JSON"
    }

    private func applyScanResult(_ result: ScanResult) {
        scanResult = result
        selectedGroupID = result.duplicateGroups.first?.id
        selectedFileID = result.duplicateGroups.first?.files.first?.id
        selectedRemovalFileIDs = Set(result.duplicateGroups.flatMap(\.recommendedRemovalFileIDs))
        scanState = .finished
        statusMessage = result.duplicateGroups.isEmpty ? "No matches found" : "Finished"
    }

    private func applyRemovalSelection(_ selectedInGroup: Set<ScannedFile.ID>, in group: DuplicateGroup) {
        guard selectedInGroup.count < group.files.count else {
            statusMessage = "At least one file is always kept."
            return
        }

        let groupIDs = Set(group.files.map(\.id))
        selectedRemovalFileIDs.subtract(groupIDs)
        selectedRemovalFileIDs.formUnion(selectedInGroup)
        updateRemovalPlan(for: group, selectedRemovalIDs: selectedInGroup)
    }

    private func updateRemovalPlan(for group: DuplicateGroup, selectedRemovalIDs: Set<ScannedFile.ID>) {
        guard var result = scanResult,
              let groupIndex = result.duplicateGroups.firstIndex(where: { $0.id == group.id })
        else {
            return
        }

        let currentGroup = result.duplicateGroups[groupIndex]
        let keepFileID = currentGroup.files.first(where: { !selectedRemovalIDs.contains($0.id) })?.id

        result.duplicateGroups[groupIndex] = DuplicateGroup(
            id: currentGroup.id,
            files: currentGroup.files,
            sha256: currentGroup.sha256,
            verificationLevel: currentGroup.verificationLevel,
            recommendedKeepFileID: keepFileID,
            recommendedRemovalFileIDs: selectedRemovalIDs,
            recommendationReasons: currentGroup.recommendationReasons
        )
        scanResult = result
    }

    private func removeMovedFilesFromResult(_ movedIDs: Set<ScannedFile.ID>) {
        guard var result = scanResult else { return }
        result.duplicateGroups = result.duplicateGroups.compactMap { group in
            let remainingFiles = group.files.filter { !movedIDs.contains($0.id) }
            guard remainingFiles.count > 1 else { return nil }
            let remainingFileIDs = Set(remainingFiles.map(\.id))
            let remainingRemovalIDs = group.recommendedRemovalFileIDs
                .subtracting(movedIDs)
                .intersection(remainingFileIDs)
            let keepFileID = remainingFiles.first(where: { !remainingRemovalIDs.contains($0.id) })?.id

            return DuplicateGroup(
                id: group.id,
                files: remainingFiles,
                sha256: group.sha256,
                verificationLevel: group.verificationLevel,
                recommendedKeepFileID: keepFileID,
                recommendedRemovalFileIDs: remainingRemovalIDs,
                recommendationReasons: group.recommendationReasons
            )
        }
        scanResult = result
    }
}
