import AppKit
import Foundation

@MainActor
final class TranscribeStore: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selection: UUID?
    @Published var settings: TranscriptionSettings
    @Published var apiKey: String
    @Published var isRecording = false
    @Published var recordingElapsed: TimeInterval = 0
    @Published var isBusy = false
    @Published var activityText = ""
    @Published var alertMessage: String?
    @Published private(set) var queuedCount = 0
    @Published private(set) var notice: Notice?
    private var pendingJobs: [@MainActor () async -> Void] = []
    private var activeMeetingID: UUID?

    private let recordingService = ScribeRecordingService()
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var activeTask: Task<Void, Never>?
    private let fileManager = FileManager.default
    private let storageDirectory: URL?
    private let trashItem: (URL) throws -> Void
    private var historyIsReadable = true
    private var didResumePending = false
    private let defaults: UserDefaults
    private let resumePending: Bool
    private var importTask: Task<Void, Never>?
    private var importCancel: CancelFlag?

    /// Library import from the standalone Meeting Scribe app.
    @Published private(set) var legacyOffer: LegacyOffer?
    @Published private(set) var importState: ImportState = .idle
    @Published private(set) var isLoaded = false
    /// False until the Keychain answered. The key loads after the library because macOS may hold the read
    /// behind an "allow access" prompt (every new ad-hoc build is a new signature).
    @Published private(set) var isKeyLoaded = false
    /// Set when a flow needs the settings sheet (e.g. missing API key). The root view presents it.
    @Published var settingsRequested = false

    static let settingsKey = "transcribe.settings"
    static let legacyDismissedKey = "transcribe.legacy-offer-dismissed"
    static let trashOriginalsKey = "transcribe.trash-original-on-delete"

    /// Shared instance used by the app. Loads the library lazily via `bootstrap()`.
    static let shared = TranscribeStore(deferLoading: true)

    init(storageDirectory: URL? = nil, apiKeyOverride: String? = nil, resumePending: Bool = true,
         defaults: UserDefaults = .standard, deferLoading: Bool = false,
         trashItem: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.trashItem = trashItem
        self.storageDirectory = storageDirectory
        self.defaults = defaults
        self.resumePending = resumePending
        apiKey = apiKeyOverride ?? (deferLoading ? "" : ScribeKeychainStore.loadAPIKey(defaults: defaults))
        if let data = defaults.data(forKey: Self.settingsKey),
           let value = try? JSONDecoder().decode(TranscriptionSettings.self, from: data) { settings = value }
        else { settings = TranscriptionSettings() }
        recordingService.onCaptureError = { [weak self] error in
            Task { @MainActor in self?.handleCaptureError(error) }
        }
        if !deferLoading {
            isKeyLoaded = true
            loadMeetings()
            finishLoading()
        }
    }

    /// Loads the key and history off the main thread. Safe to call repeatedly.
    func bootstrap() async {
        guard !isLoaded else { return }
        let url = indexURL
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[Meeting], Error>? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Result { try JSONDecoder().decode([Meeting].self, from: Data(contentsOf: url)) }
        }.value
        apply(loaded: result)
        finishLoading()
        await refreshLegacyOffer()
        // Never block the library on the Keychain: a pending macOS prompt used to leave the rack empty.
        let key = await Task.detached(priority: .userInitiated) { ScribeKeychainStore.loadAPIKey() }.value
        if apiKey.isEmpty { apiKey = key }
        isKeyLoaded = true
        resumePendingJobs()
    }

    private func finishLoading() {
        repairRetryTitles()
        selection = meetings.first?.id
        for meeting in meetings where [.preparing, .uploading].contains(meeting.status) {
            update(meeting.id) { $0.status = .failed; $0.errorMessage = "The app closed before AssemblyAI returned an ID. Try again." }
        }
        isLoaded = true
        resumePendingJobs()
    }

    /// Older versions retried by re-importing the library copy, so the new item was titled "source".
    /// Give it the title of the item whose folder it came from.
    private func repairRetryTitles() {
        var changed = false
        // Older versions saved URLSession's raw "cancelled" text as the error.
        for index in meetings.indices where meetings[index].errorMessage?.lowercased() == "cancelled" {
            meetings[index].errorMessage = "Processing canceled. Try again whenever you are ready."
            changed = true
        }
        for index in meetings.indices where meetings[index].title.lowercased() == "source" {
            guard let original = meetings[index].originalPath else { continue }
            let folder = URL(filePath: original).deletingLastPathComponent().standardizedFileURL.path
            if let owner = meetings.first(where: { URL(filePath: $0.outputDirectory).standardizedFileURL.path == folder && $0.title.lowercased() != "source" }) {
                meetings[index].title = owner.title
                changed = true
            }
        }
        if changed { persistMeetings() }
    }

    private func resumePendingJobs() {
        if resumePending, hasAPIKey, !didResumePending {
            didResumePending = true
            for pending in meetings where [.transcribing, .summarizing].contains(pending.status) {
                if pending.status == .summarizing, !pending.text.isEmpty {
                    retrySummary(pending)
                } else if pending.transcriptID != nil {
                    enqueue { [weak self] in await self?.resumeTranscript(pending) }
                }
            }
        }
    }

    /// True while a recording, a transcription or a queued job is running. Use it to confirm quitting.
    var hasWorkInProgress: Bool { isBusy || isRecording || queuedCount > 0 || importState.isRunning }

    struct Notice: Equatable, Identifiable { let id = UUID(); let text: String }
    struct RemovalResult: Equatable {
        var removed = 0; var skipped = 0; var failed = 0
        /// Original files (outside the library) moved to the Trash together with their transcriptions.
        var originalsTrashed = 0
        var originalsFailed = 0
        /// Originals left alone because the file no longer matches what was imported.
        var originalsChanged = 0
    }
    struct LegacyOffer: Equatable { var count: Int?; var bytes: Int64? }
    enum ImportState: Equatable {
        case idle, running(progress: Double), done(String), failed(String)
        var isRunning: Bool { if case .running = self { true } else { false } }
    }

    var completedMeetings: [Meeting] { meetings.filter { $0.status == .completed } }
    var failedMeetings: [Meeting] { meetings.filter { $0.status == .failed } }
    var inFlightMeetings: [Meeting] { meetings.filter { Self.isInFlight($0.status) } }

    nonisolated static func isInFlight(_ status: MeetingStatus) -> Bool {
        switch status {
        case .ready, .preparing, .uploading, .transcribing, .summarizing: true
        case .completed, .failed: false
        }
    }

    /// True unless the meeting is being processed, or is in flight while work is running or queued.
    /// When the app is idle, a meeting stuck in an in-flight status (e.g. after a crash) can still be removed.
    func canDelete(_ meeting: Meeting) -> Bool {
        guard activeMeetingID != meeting.id else { return false }
        return !(Self.isInFlight(meeting.status) && (isBusy || isRecording || queuedCount > 0))
    }

    /// True only for a real (non-symlink) directory strictly inside meetingsRoot.
    func isSafeToTrash(_ directory: URL) -> Bool {
        let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return false }
        let root = meetingsRoot.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return target.count > root.count && Array(target.prefix(root.count)) == root
    }

    private var searchCache: [UUID: (stamp: Int, text: String)] = [:]
    /// Folded (lowercase, diacritic-free) title + transcript, cached so typing never re-folds large texts.
    func searchableText(for meeting: Meeting) -> String {
        let stamp = meeting.text.utf8.count &+ meeting.title.utf8.count
        if let hit = searchCache[meeting.id], hit.stamp == stamp { return hit.text }
        let folded = (meeting.title + "\n" + meeting.text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        searchCache[meeting.id] = (stamp, folded)
        return folded
    }

    func showNotice(_ text: String) { notice = Notice(text: text) }
    func dismissNotice() { notice = nil }

    var selectedMeeting: Meeting? { meetings.first { $0.id == selection } }
    /// `~/Library/Application Support/File Foundry/Transcribe` (index + `Meetings/`), or the test override.
    var libraryDirectory: URL {
        if let storageDirectory { return storageDirectory }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appending(path: "File Foundry/Transcribe", directoryHint: .isDirectory)
    }
    var meetingsRoot: URL { libraryDirectory.appending(path: "Meetings", directoryHint: .isDirectory) }

    // MARK: Library import (Meeting Scribe)

    func refreshLegacyOffer() async {
        // Offered even when the library already has items: the import skips meetings that are already here.
        guard historyIsReadable, !defaults.bool(forKey: Self.legacyDismissedKey) else { legacyOffer = nil; return }
        legacyOffer = await probeLegacy()
    }

    /// Whether an old Meeting Scribe library can be imported (also offered later from the settings).
    func probeLegacy() async -> LegacyOffer? {
        await Task.detached(priority: .utility) { () -> LegacyOffer? in
            do {
                guard let probe = try ScribeLibraryImporter.probe() else { return nil }
                return LegacyOffer(count: probe.count, bytes: probe.bytes)
            } catch ScribeLibraryImporter.ImportError.permissionDenied {
                return LegacyOffer(count: nil, bytes: nil)
            } catch { return nil }
        }.value
    }

    func dismissLegacyOffer() {
        defaults.set(true, forKey: Self.legacyDismissedKey)
        legacyOffer = nil
    }

    func importLegacyLibrary() {
        guard !importState.isRunning, !isBusy, !isRecording, historyIsReadable else { return }
        importState = .running(progress: 0)
        let destination = libraryDirectory
        let cancelFlag = CancelFlag()
        importCancel = cancelFlag
        importTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ScribeLibraryImporter.Outcome, Error> in
                Result {
                    try ScribeLibraryImporter.performImport(
                        destinationRoot: destination,
                        progress: { value in Task { @MainActor in self?.importProgress(value) } },
                        isCancelled: { cancelFlag.isSet })
                }
            }.value
            self?.finishImport(outcome)
        }
    }

    func cancelLegacyImport() { importCancel?.set() }

    private func importProgress(_ value: Double) {
        if importState.isRunning { importState = .running(progress: value) }
    }

    private func finishImport(_ result: Result<ScribeLibraryImporter.Outcome, Error>) {
        importTask = nil; importCancel = nil
        switch result {
        case .success(let outcome):
            meetings = outcome.meetings
            selection = meetings.first?.id
            searchCache = [:]
            if defaults.data(forKey: Self.settingsKey) == nil,
               let data = ScribeLibraryImporter.legacySettingsData(),
               let value = try? JSONDecoder().decode(TranscriptionSettings.self, from: data) {
                settings = value
                defaults.set(data, forKey: Self.settingsKey)
            }
            legacyOffer = nil
            defaults.set(true, forKey: Self.legacyDismissedKey)
            var text = outcome.imported == 1 ? "1 transcript imported from Meeting Scribe" : "\(outcome.imported) transcripts imported from Meeting Scribe"
            if outcome.alreadyPresent > 0 { text += " · \(outcome.alreadyPresent) already here" }
            if outcome.skippedLinks > 0 { text += " · \(outcome.skippedLinks) \(outcome.skippedLinks == 1 ? "symbolic link skipped" : "symbolic links skipped")" }
            importState = .done(text)
            showNotice(text)
        case .failure(let error):
            if let known = error as? ScribeLibraryImporter.ImportError, known == .cancelled {
                importState = .idle
            } else {
                importState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: Preferences

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    func savePreferences() {
        do {
            apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try ScribeKeychainStore.saveAPIKey(apiKey)
            defaults.set(true, forKey: "transcribe.keychain-migration-complete")
            saveSettings()
        } catch { alertMessage = error.localizedDescription }
    }

    func validateAPIKey() {
        guard requireAPIKey(), !isBusy, !isRecording else { return }
        isBusy = true; activityText = "Checking key…"
        activeTask = Task {
            defer { isBusy = false; activityText = ""; activeTask = nil; startNextJob() }
            do {
                try await AssemblyAIClient(apiKey: apiKey, region: settings.region).validateKey()
                alertMessage = "Key is valid. Connected to AssemblyAI."
            } catch { alertMessage = error.localizedDescription }
        }
    }

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @discardableResult
    private func requireAPIKey() -> Bool {
        guard hasAPIKey else {
            alertMessage = "Add your AssemblyAI API key in Settings before transcribing."
            settingsRequested = true
            return false
        }
        return true
    }

    func importMedia(_ url: URL) { importMedia([url]) }

    func importMedia(_ urls: [URL]) {
        guard requireAPIKey() else { return }
        for url in urls {
            do { try ScribeMediaProcessor.validateImport(url) }
            catch { alertMessage = error.localizedDescription; continue }
            enqueue { [weak self] in
                await self?.createAndTranscribe(sourceURL: url, suggestedTitle: url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    func enqueue(_ job: @escaping @MainActor () async -> Void) {
        guard !importState.isRunning else {
            alertMessage = "Wait for the library import to finish before transcribing."
            return
        }
        guard historyIsReadable else {
            alertMessage = "The history couldn't be read. The original file was kept. Open the data folder and restore a valid copy of meetings.json before continuing."
            return
        }
        pendingJobs.append(job)
        queuedCount = pendingJobs.count
        startNextJob()
    }

    private func startNextJob() {
        guard activeTask == nil, !isBusy, !isRecording, !pendingJobs.isEmpty else { return }
        let job = pendingJobs.removeFirst()
        queuedCount = pendingJobs.count
        isBusy = true
        activeTask = Task {
            await job()
            activeMeetingID = nil
            isBusy = false
            activityText = ""
            activeTask = nil
            startNextJob()
        }
    }

    func startRecording(includeMicrophone: Bool, recordScreen: Bool) {
        guard !isRecording, !isBusy, !importState.isRunning, historyIsReadable, requireAPIKey() else { return }
        let title = "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))"
        let directory = makeMeetingDirectory(title: title)
        isBusy = true; activityText = "Requesting permissions…"
        activeTask = Task {
            defer { activeMeetingID = nil; activeTask = nil; startNextJob() }
            do {
                try await recordingService.start(in: directory, includeMicrophone: includeMicrophone, recordScreen: recordScreen)
                try Task.checkCancellation()
                isRecording = true; isBusy = false; activityText = ""
                recordingStartedAt = Date(); recordingElapsed = 0
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.recordingElapsed = Date().timeIntervalSince(self?.recordingStartedAt ?? Date()) }
                }
            } catch is CancellationError {
                await recordingService.cancel(); isBusy = false; activityText = ""
            } catch { isBusy = false; activityText = ""; alertMessage = error.localizedDescription }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false; recordingTimer?.invalidate(); recordingTimer = nil
        isBusy = true; activityText = "Finishing and mixing audio…"
        activeTask = Task {
            defer { activeMeetingID = nil; activeTask = nil; startNextJob() }
            do {
                let result = try await recordingService.stop()
                try Task.checkCancellation()
                isBusy = false; activityText = ""
                await createAndTranscribe(sourceURL: result.audioURL, suggestedTitle: "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))", existingDirectory: result.audioURL.deletingLastPathComponent(), duration: result.duration)
            } catch is CancellationError {
                isBusy = false; activityText = ""
            } catch { isBusy = false; activityText = ""; alertMessage = error.localizedDescription }
        }
    }

    func cancelActiveWork() {
        pendingJobs.removeAll(); queuedCount = 0
        activeTask?.cancel()
        if isRecording {
            isRecording = false; recordingTimer?.invalidate(); recordingTimer = nil
            activeTask = Task {
                await recordingService.cancel()
                isBusy = false; activityText = ""; activeTask = nil
                startNextJob()
            }
        }
        if let pending = meetings.first(where: { $0.id == activeMeetingID }) {
            update(pending.id) { $0.markProcessingCancelled() }
        }
        isBusy = activeTask != nil; activityText = isBusy ? "Canceling…" : ""
    }

    func retry(_ meeting: Meeting) {
        guard requireAPIKey() else { return }
        if meeting.transcriptID != nil { enqueue { [weak self] in await self?.resumeTranscript(meeting) } }
        else {
            let source = URL(filePath: meeting.sourcePath)
            guard isInsideLibrary(source) || isFingerprintedOriginal(meeting, path: meeting.sourcePath) else {
                alertMessage = "The source file is outside the library and wasn't imported by this app, so it won't be sent."
                return
            }
            // Retry the same item in place: same title, folder and original, no duplicate named "source".
            enqueue { [weak self] in
                await self?.createAndTranscribe(sourceURL: source, suggestedTitle: meeting.title,
                                                existingDirectory: URL(filePath: meeting.outputDirectory),
                                                duration: meeting.durationSeconds > 0 ? meeting.durationSeconds : nil,
                                                replacing: meeting)
            }
        }
    }

    private func standardizedPath(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// True when `url` is inside the library root (symlinks resolved, case-insensitive for APFS).
    func isInsideLibrary(_ url: URL) -> Bool {
        let root = libraryDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() }
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() }
        return target.count >= root.count && Array(target.prefix(root.count)) == root
    }

    /// `path` is the original this app recorded (with a fingerprint) for `meeting`.
    private func isFingerprintedOriginal(_ meeting: Meeting, path: String) -> Bool {
        guard meeting.originalFingerprint != nil, let original = meeting.originalPath else { return false }
        return standardizedPath(original) == standardizedPath(path)
    }

    /// Another meeting, not in `removing`, uses the same output folder.
    private func isOutputDirectoryShared(_ meeting: Meeting, excluding removing: Set<UUID>) -> Bool {
        let key = standardizedPath(meeting.outputDirectory)
        return meetings.contains { $0.id != meeting.id && !removing.contains($0.id) && standardizedPath($0.outputDirectory) == key }
    }

    func rename(_ meeting: Meeting, title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        update(meeting.id) { $0.title = value }
    }

    func reveal(_ meeting: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: meeting.outputDirectory)])
    }

    func remove(_ meeting: Meeting, deleteFiles: Bool) {
        guard activeMeetingID != meeting.id else {
            alertMessage = "Cancel processing before deleting this transcript."
            return
        }
        let directory = URL(filePath: meeting.outputDirectory)
        if deleteFiles, fileManager.fileExists(atPath: directory.path), isSafeToTrash(directory),
           !isOutputDirectoryShared(meeting, excluding: []) {
            do { try trashItem(directory) }
            catch {
                alertMessage = "Couldn't move the files to the Trash. The history was kept. Try again: \(error.localizedDescription)"
                return
            }
        }
        meetings.removeAll { $0.id == meeting.id }
        if selection == meeting.id { selection = meetings.first?.id }
        persistMeetings()
    }

    /// True only for a regular file (not a symlink, not a directory) that lives outside the library root.
    func isSafeOriginalToTrash(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let url = URL(filePath: path)
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]),
              values.isSymbolicLink != true, values.isDirectory != true, values.isRegularFile == true else { return false }
        let root = libraryDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let insideLibrary = target.count >= root.count && Array(target.prefix(root.count)) == root
        return !insideLibrary
    }

    /// Moves several meetings to the Trash. Skips the active meeting and any in flight; persists once.
    /// With `alsoTrashOriginals`, each meeting's original imported file is trashed too (when it is safe to).
    @discardableResult
    func remove(ids: Set<UUID>, alsoTrashOriginals: Bool = false) -> RemovalResult {
        var result = RemovalResult()
        var removedIDs = Set<UUID>()
        var originals: [(meeting: Meeting, path: String)] = []
        let removable = Set(meetings.filter { ids.contains($0.id) && canDelete($0) }.map(\.id))
        for meeting in meetings where ids.contains(meeting.id) {
            guard removable.contains(meeting.id) else { result.skipped += 1; continue }
            let directory = URL(filePath: meeting.outputDirectory)
            if fileManager.fileExists(atPath: directory.path), isSafeToTrash(directory),
               !isOutputDirectoryShared(meeting, excluding: removable) {
                do { try trashItem(directory) }
                catch { result.failed += 1; continue }
            }
            removedIDs.insert(meeting.id)
            // Only originals this app recorded (path + fingerprint) are eligible; never `sourcePath`.
            if alsoTrashOriginals, meeting.originalFingerprint != nil, let path = meeting.originalPath {
                originals.append((meeting, path))
            }
        }
        result.removed = removedIDs.count
        if alsoTrashOriginals {
            // Never trash a file another remaining transcription still points to.
            let stillReferenced = Set(meetings.filter { !removedIDs.contains($0.id) }
                .flatMap { [$0.sourcePath, $0.originalPath].compactMap { $0 } }
                .map { URL(filePath: $0).standardizedFileURL.path })
            for (meeting, path) in originals where removedIDs.contains(meeting.id) {
                let key = URL(filePath: path).standardizedFileURL.path
                guard !stillReferenced.contains(key), isSafeOriginalToTrash(path) else { continue }
                guard meeting.originalFingerprint?.matches(path: path) == true else { result.originalsChanged += 1; continue }
                do { try trashItem(URL(filePath: path)); result.originalsTrashed += 1 }
                catch { result.originalsFailed += 1 }
            }
        }
        if !removedIDs.isEmpty {
            let oldIndex = meetings.firstIndex { $0.id == selection }
            meetings.removeAll { removedIDs.contains($0.id) }
            if let selection, removedIDs.contains(selection) {
                let index = min(oldIndex ?? 0, max(meetings.count - 1, 0))
                self.selection = meetings.indices.contains(index) ? meetings[index].id : nil
            }
            persistMeetings()
        }
        announce(result)
        return result
    }

    private func announce(_ result: RemovalResult) {
        var problems: [String] = []
        if result.failed > 0 {
            problems.append("Couldn't move \(result.failed) \(result.failed == 1 ? "folder" : "folders") to the Trash. These items were kept in the library.")
        }
        if result.originalsFailed > 0 {
            problems.append("Couldn't move \(result.originalsFailed) \(result.originalsFailed == 1 ? "original file" : "original files") to the Trash.")
        }
        if result.originalsChanged > 0 {
            problems.append("Original changed; not moved (\(result.originalsChanged) \(result.originalsChanged == 1 ? "file" : "files")).")
        }
        if !problems.isEmpty { alertMessage = problems.joined(separator: " ") }
        guard result.removed > 0 else {
            if result.skipped > 0 { showNotice("Items in progress can't be moved to the Trash.") }
            return
        }
        var text = result.removed == 1 ? "1 transcript" : "\(result.removed) transcripts"
        if result.originalsTrashed > 0 {
            text += " and \(result.originalsTrashed) \(result.originalsTrashed == 1 ? "original" : "originals")"
        }
        text += " moved to the Trash"
        if result.skipped > 0 { text += " · \(result.skipped) in progress kept" }
        showNotice(text)
    }

    private func createAndTranscribe(sourceURL: URL, suggestedTitle: String, existingDirectory: URL? = nil, duration: Double? = nil,
                                     replacing previous: Meeting? = nil) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertMessage = "Add your AssemblyAI API key in Settings before transcribing."
            settingsRequested = true
            return
        }
        let directory = existingDirectory ?? makeMeetingDirectory(title: suggestedTitle)
        var createdMeetingID: UUID?
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let localSource: URL
            var fingerprint: FileFingerprint?
            if sourceURL.deletingLastPathComponent() == directory { localSource = sourceURL }
            else {
                if !isInsideLibrary(sourceURL) { fingerprint = FileFingerprint.capture(path: sourceURL.path) }
                let destination = directory.appending(path: "source.\(sourceURL.pathExtension.isEmpty ? "media" : sourceURL.pathExtension)")
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: sourceURL, to: destination)
                // If the original changed while it was copied, it is not the file we imported: never offer to trash it.
                if let captured = fingerprint, !captured.matches(path: sourceURL.path) { fingerprint = nil }
                localSource = destination
            }
            let measuredDuration: Double
            if let duration { measuredDuration = duration }
            else { measuredDuration = await ScribeMediaProcessor.duration(of: localSource) }
            var meeting = Meeting(title: suggestedTitle, sourceURL: localSource, outputDirectory: directory, durationSeconds: measuredDuration,
                                  originalURL: localSource == sourceURL ? nil : sourceURL, originalFingerprint: fingerprint)
            var insertAt = 0
            if let previous {
                meeting.id = previous.id
                meeting.createdAt = previous.createdAt
                meeting.originalPath = previous.originalPath
                meeting.originalFingerprint = previous.originalFingerprint
                if let index = meetings.firstIndex(where: { $0.id == previous.id }) {
                    insertAt = index
                    meetings.remove(at: index)
                }
            }
            createdMeetingID = meeting.id
            activeMeetingID = meeting.id
            meeting.status = .preparing; meeting.progress = 0.05
            meetings.insert(meeting, at: insertAt); selection = meeting.id; persistMeetings()
            isBusy = true; activityText = "Preparing media…"

            let preparedURL: URL
            if localSource.lastPathComponent == "meeting-audio.m4a" { preparedURL = localSource }
            else { preparedURL = try await ScribeMediaProcessor.prepareAudio(from: localSource, in: directory) }
            try Task.checkCancellation()
            update(meeting.id) { $0.status = .uploading; $0.progress = 0.2 }
            activityText = "Uploading to AssemblyAI…"
            let client = AssemblyAIClient(apiKey: apiKey, region: settings.region)
            let uploadURL = try await client.upload(fileURL: preparedURL)
            try Task.checkCancellation()
            let transcriptID = try await client.submit(audioURL: uploadURL, settings: settings)
            update(meeting.id) { $0.transcriptID = transcriptID; $0.status = .transcribing; $0.progress = 0.45 }
            activityText = "Transcribing with \(settings.model.title)…"
            let completed = try await client.waitForTranscript(id: transcriptID) { [weak self] status in
                await MainActor.run { self?.activityText = status == "queued" ? "Queued at AssemblyAI…" : "Transcribing…" }
            }
            let result = completed.result
            update(meeting.id) {
                $0.durationSeconds = result.audioDuration ?? measuredDuration
                $0.text = result.text ?? ""
                $0.utterances = result.utterances ?? []
                $0.words = result.words ?? []
                $0.speechModelUsed = result.speechModelUsed
                $0.languageCode = result.languageCode
                $0.progress = 0.82
            }
            if settings.generateSummary {
                update(meeting.id) { $0.status = .summarizing }
                activityText = "Writing meeting notes…"
                do {
                    let summary = try await client.summary(transcriptText: result.text ?? "")
                    update(meeting.id) { $0.summary = summary; $0.summaryError = nil }
                } catch is CancellationError { throw CancellationError() }
                catch { update(meeting.id) { $0.summaryError = error.localizedDescription } }
            }
            activityText = "Exporting files…"
            async let srt = try? client.subtitle(id: transcriptID, format: "srt")
            async let vtt = try? client.subtitle(id: transcriptID, format: "vtt")
            let subtitleValues = await (srt, vtt)
            guard let finalMeeting = meetings.first(where: { $0.id == meeting.id }) else { return }
            try ScribeExportService.saveAll(meeting: finalMeeting, rawJSON: completed.rawData, srt: subtitleValues.0, vtt: subtitleValues.1)
            update(meeting.id) { $0.status = .completed; $0.progress = 1 }
            if settings.deleteRemoteAfterSave {
                do { try await client.deleteTranscript(id: transcriptID) }
                catch { alertMessage = "The transcript is saved. Couldn't delete the copy in AssemblyAI: \(error.localizedDescription)" }
            }
            isBusy = false; activityText = ""
        } catch is CancellationError {
            isBusy = false; activityText = ""
        } catch where Task.isCancelled || (error as? URLError)?.code == .cancelled {
            // URLSession reports a cancelled upload as URLError.cancelled, not CancellationError.
            if let id = createdMeetingID, let current = meetings.first(where: { $0.id == id }), current.status != .failed {
                update(id) { $0.markProcessingCancelled() }
            }
            isBusy = false; activityText = ""
        } catch {
            if let id = createdMeetingID { update(id) { $0.status = .failed; $0.errorMessage = error.localizedDescription } }
            isBusy = false; activityText = ""; alertMessage = error.localizedDescription
        }
    }

    private func makeMeetingDirectory(title: String) -> URL {
        let safe = title.replacingOccurrences(of: "[^a-zA-Z0-9À-ÿ_-]+", with: "-", options: .regularExpression)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return meetingsRoot.appending(path: "\(stamp)-\(safe)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    private func handleCaptureError(_ error: Error) {
        guard isRecording else { return }
        isRecording = false; recordingTimer?.invalidate(); recordingTimer = nil
        isBusy = false; activityText = ""; alertMessage = "Recording was interrupted by macOS: \(error.localizedDescription)"
        activeTask = Task {
            await recordingService.cancel()
            activeTask = nil
            startNextJob()
        }
    }

    private func resumeTranscript(_ meeting: Meeting) async {
        guard meetings.contains(where: { $0.id == meeting.id }), let transcriptID = meeting.transcriptID, requireAPIKey() else { return }
        activeMeetingID = meeting.id
        isBusy = true; activityText = "Resuming existing transcript…"
        update(meeting.id) { $0.status = .transcribing; $0.errorMessage = nil }
        do {
            let client = AssemblyAIClient(apiKey: apiKey, region: settings.region)
            let completed = try await client.waitForTranscript(id: transcriptID) { [weak self] status in
                await MainActor.run { self?.activityText = status == "queued" ? "Queued at AssemblyAI…" : "Transcribing…" }
            }
            let result = completed.result
            update(meeting.id) {
                $0.durationSeconds = result.audioDuration ?? $0.durationSeconds
                $0.text = result.text ?? ""
                $0.utterances = result.utterances ?? []
                $0.words = result.words ?? []
                $0.speechModelUsed = result.speechModelUsed
                $0.languageCode = result.languageCode
                $0.progress = 0.82
            }
            if settings.generateSummary {
                update(meeting.id) { $0.status = .summarizing }
                activityText = "Writing meeting notes…"
                do { let value = try await client.summary(transcriptText: result.text ?? ""); update(meeting.id) { $0.summary = value; $0.summaryError = nil } }
                catch is CancellationError { throw CancellationError() }
                catch { update(meeting.id) { $0.summaryError = error.localizedDescription } }
            }
            async let srt = try? client.subtitle(id: transcriptID, format: "srt")
            async let vtt = try? client.subtitle(id: transcriptID, format: "vtt")
            let subtitles = await (srt, vtt)
            if let final = meetings.first(where: { $0.id == meeting.id }) {
                try ScribeExportService.saveAll(meeting: final, rawJSON: completed.rawData, srt: subtitles.0, vtt: subtitles.1)
            }
            update(meeting.id) { $0.status = .completed; $0.progress = 1 }
            if settings.deleteRemoteAfterSave {
                do { try await client.deleteTranscript(id: transcriptID) }
                catch { alertMessage = "The transcript is saved. Couldn't delete the copy in AssemblyAI: \(error.localizedDescription)" }
            }
            isBusy = false; activityText = ""
        } catch is CancellationError {
            isBusy = false; activityText = ""
        } catch {
            update(meeting.id) { $0.status = .failed; $0.errorMessage = error.localizedDescription }
            isBusy = false; activityText = ""; alertMessage = error.localizedDescription
        }
    }
    func retrySummary(_ meeting: Meeting) {
        guard requireAPIKey(), !meeting.text.isEmpty else { return }
        enqueue { [weak self] in
            guard let self, self.meetings.contains(where: { $0.id == meeting.id }) else { return }
            self.activeMeetingID = meeting.id
            self.activityText = "Writing summary…"
            self.update(meeting.id) { $0.status = .summarizing; $0.summaryError = nil }
            do {
                let client = AssemblyAIClient(apiKey: self.apiKey, region: self.settings.region)
                let summary = try await client.summary(transcriptText: meeting.text)
                try Task.checkCancellation()
                self.update(meeting.id) { $0.summary = summary; $0.status = .completed; $0.progress = 1 }
                let url = URL(filePath: meeting.outputDirectory).appending(path: "summary.md")
                try summary.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.update(meeting.id) {
                    $0.status = .completed
                    $0.summaryError = error is CancellationError ? "Summary canceled. You can try again." : error.localizedDescription
                }
            }
        }
    }

    private func update(_ id: UUID, change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[index]); persistMeetings()
    }
    private var indexURL: URL { libraryDirectory.appending(path: "meetings.json") }
    private func loadMeetings() {
        guard fileManager.fileExists(atPath: indexURL.path) else { return }
        apply(loaded: Result { try JSONDecoder().decode([Meeting].self, from: Data(contentsOf: indexURL)) })
    }
    private func apply(loaded: Result<[Meeting], Error>?) {
        guard let loaded else { return }
        let value: [Meeting]
        switch loaded {
        case .success(let decoded): value = decoded
        case .failure:
            historyIsReadable = false
            alertMessage = "Couldn't read the history at \(indexURL.path). The file was kept. Restore a valid copy of meetings.json and reopen the app."
            return
        }
        meetings = value.map { meeting in
            var restored = meeting
            if let summary = restored.summary, summary.hasPrefix("_Resumo não gerado:") {
                restored.summary = nil
                restored.summaryError = "The previous summary failed. Try generating it again, or check your AssemblyAI summary access."
            }
            return restored
        }
    }
    private func persistMeetings() {
        guard historyIsReadable else { return }
        do {
            try fileManager.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            // Keep backward-compatible decoding by storing dates in the default format for now.
            encoder.dateEncodingStrategy = .deferredToDate
            try encoder.encode(meetings).write(to: indexURL, options: .atomic)
        } catch { alertMessage = "Couldn't save the history: \(error.localizedDescription)" }
    }
}

/// Thread-safe cancellation flag shared with the background import.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
