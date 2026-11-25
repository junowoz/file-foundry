import AppKit
import Foundation
import Observation

enum WorkflowStep: Int, CaseIterable, Identifiable {
    case sources, configure, review, copy, report
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .sources: "Sources"
        case .configure: "Configure"
        case .review: "Review"
        case .copy: "Copy"
        case .report: "Report"
        }
    }
}

@MainActor
@Observable
final class AppStore {
    var step: WorkflowStep = .sources
    var sources: [SourceRoot] = []
    var destinationParent: DestinationRoot?
    var summary: ScanSummary?
    var plan: ExportPlan?
    var template = TemplateEngine.defaultTemplate
    var filesystemFallback = false
    var acceptsIncompleteScan = false
    var isWorking = false
    var progressCompleted = 0
    var progressTotal = 0
    var statusMessage = "Add one or more folders to get started."
    var errorMessage: String?
    var outputURL: URL?
    var manifest: ExportManifest?

    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private let scanner = MediaScanner()
    @ObservationIgnored private let planner = ExportPlanner()
    @ObservationIgnored private let copyEngine = VerifiedCopyEngine()
    @ObservationIgnored private let bookmarkService = BookmarkService()
    @ObservationIgnored private let policy = FileSystemPolicy()

    func chooseSources() {
        let panel = NSOpenPanel()
        panel.title = "Choose Media Folders"
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.presentAsSheet { [self] ok in
            if ok { addSourceURLs(panel.urls) }
        }
    }

    func addSourceURLs(_ urls: [URL]) {
        errorMessage = nil
        for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if sources.contains(where: { contains($0.location.url, canonical) || contains(canonical, $0.location.url) }) {
                errorMessage = "This folder is already included in another source."
                continue
            }
            do {
                _ = canonical.startAccessingSecurityScopedResource()
                if let bookmark = try? bookmarkService.sourceBookmark(for: canonical) {
                    canonical.stopAccessingSecurityScopedResource()
                    let resolved = try bookmarkService.resolveSource(bookmark)
                    _ = resolved.startAccessingSecurityScopedResource()
                    sources.append(try SourceRoot(url: resolved, bookmark: bookmark))
                } else {
                    sources.append(try SourceRoot(url: canonical))
                }
            } catch { errorMessage = error.localizedDescription }
        }
        sources.sort { $0.location.url.path.localizedStandardCompare($1.location.url.path) == .orderedAscending }
        summary = nil; plan = nil
        statusMessage = sources.isEmpty ? "Add one or more folders to get started." : "\(sources.count) folder(s) ready to scan."
    }

    func removeSource(_ source: SourceRoot) {
        sources.removeAll { $0.id == source.id }
        source.location.url.stopAccessingSecurityScopedResource()
        summary = nil; plan = nil
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Where to Create the Organized Library"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.presentAsSheet { [self] ok in
            guard ok, let url = panel.url else { return }
            do {
                destinationParent?.url.stopAccessingSecurityScopedResource()
                _ = url.startAccessingSecurityScopedResource()
                if let bookmark = try? bookmarkService.destinationBookmark(for: url) {
                    url.stopAccessingSecurityScopedResource()
                    let resolved = try bookmarkService.resolveDestination(bookmark)
                    _ = resolved.startAccessingSecurityScopedResource()
                    destinationParent = try DestinationRoot(url: resolved, bookmark: bookmark)
                } else {
                    destinationParent = try DestinationRoot(url: url)
                }
                refreshPlan()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func scan() {
        guard !sources.isEmpty else { return }
        errorMessage = nil; isWorking = true; statusMessage = "Scanning folders. Nothing in your sources is changed."
        operationTask = Task {
            do {
                let result = try await scanner.scan(sources: sources, filesystemFallback: filesystemFallback)
                summary = result
                acceptsIncompleteScan = false
                let planner = planner, sources = sources, template = template
                plan = try await Task.detached(priority: .userInitiated) {
                    try planner.makePlan(summary: result, sources: sources, template: template)
                }.value
                step = .configure
                statusMessage = "Scan complete: \(result.records.count) items found."
            } catch is CancellationError {
                statusMessage = "Scan canceled. Nothing in your sources was changed."
            } catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }

    func refreshPlan() {
        guard let summary else { return }
        do {
            plan = try planner.makePlan(summary: summary, sources: sources, template: template)
            errorMessage = nil
        } catch { plan = nil; errorMessage = error.localizedDescription }
    }

    func review() {
        if let summary, !summary.isComplete, !acceptsIncompleteScan {
            errorMessage = "The scan hit \(summary.enumerationErrorCount) access error(s). Review them and confirm you want an incomplete export."
            return
        }
        guard let destinationParent, plan != nil else {
            errorMessage = "Choose a valid destination folder before reviewing."
            return
        }
        do {
            let candidate = destinationParent.url.appendingPathComponent("File Foundry — Organized Media", isDirectory: true)
            try policy.validateDisjoint(sources: sources, destination: DestinationRoot(url: candidate))
            step = .review
        } catch { errorMessage = error.localizedDescription }
    }

    func export() {
        guard let plan, let destinationParent else { return }
        step = .copy; isWorking = true; errorMessage = nil
        progressCompleted = 0; progressTotal = plan.items.count
        statusMessage = "Copying files and verifying checksums…"
        operationTask = Task {
            do {
                let (url, exportManifest) = try await copyEngine.export(plan: plan, sources: sources, destinationParent: destinationParent) { [weak self] completed, total in
                    await MainActor.run {
                        self?.progressCompleted = completed
                        self?.progressTotal = total
                    }
                }
                outputURL = url; manifest = exportManifest; step = .report
                let failures = exportManifest.records.filter { $0.status == .failed }.count
                statusMessage = failures == 0 ? "Export complete and verified." : "Export complete. \(failures) item(s) need review."
            } catch is CancellationError {
                statusMessage = "Export canceled. Verified copies were kept."
            } catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }

    func cancel() { operationTask?.cancel() }

    var canStartOver: Bool { !isWorking && (!sources.isEmpty || destinationParent != nil || summary != nil || step != .sources) }

    /// Back to the first step with nothing chosen. Never touches files already copied.
    func startOver() {
        guard !isWorking else { return }
        sources = []
        destinationParent = nil
        summary = nil
        plan = nil
        manifest = nil
        outputURL = nil
        errorMessage = nil
        acceptsIncompleteScan = false
        progressCompleted = 0
        progressTotal = 0
        step = .sources
        statusMessage = "Add one or more folders to get started."
    }

    func revealOutput() {
        if let outputURL { NSWorkspace.shared.activateFileViewerSelecting([outputURL]) }
    }

    private func contains(_ parent: URL, _ child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }
}
