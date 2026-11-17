import AppKit
import Foundation
import Observation

enum WorkflowStep: Int, CaseIterable, Identifiable {
    case sources, configure, review, copy, report
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .sources: "Fontes"
        case .configure: "Configurar"
        case .review: "Revisar"
        case .copy: "Copiar"
        case .report: "Relatório"
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
    var statusMessage = "Adicione uma ou mais pastas para começar."
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
        panel.title = "Escolha as pastas de mídia"
        panel.prompt = "Adicionar"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addSourceURLs(panel.urls) }
    }

    func addSourceURLs(_ urls: [URL]) {
        errorMessage = nil
        for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if sources.contains(where: { contains($0.location.url, canonical) || contains(canonical, $0.location.url) }) {
                errorMessage = "Esta pasta já está incluída por outra origem."
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
        statusMessage = sources.isEmpty ? "Adicione uma ou mais pastas para começar." : "\(sources.count) pasta(s) pronta(s) para análise."
    }

    func removeSource(_ source: SourceRoot) {
        sources.removeAll { $0.id == source.id }
        source.location.url.stopAccessingSecurityScopedResource()
        summary = nil; plan = nil
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Escolha onde criar a biblioteca organizada"
        panel.prompt = "Escolher"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
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
        errorMessage = nil; isWorking = true; statusMessage = "Analisando pastas sem escrever nas origens…"
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
                statusMessage = "Análise concluída: \(result.records.count) itens contabilizados."
            } catch is CancellationError {
                statusMessage = "Análise cancelada. Nenhuma origem foi alterada."
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
            errorMessage = "A análise encontrou \(summary.enumerationErrorCount) erro(s) de acesso. Revise e confirme que deseja continuar com uma exportação incompleta."
            return
        }
        guard let destinationParent, plan != nil else {
            errorMessage = "Escolha uma pasta de destino válida antes de revisar."
            return
        }
        do {
            let candidate = destinationParent.url.appendingPathComponent("File Foundry — Mídia organizada", isDirectory: true)
            try policy.validateDisjoint(sources: sources, destination: DestinationRoot(url: candidate))
            step = .review
        } catch { errorMessage = error.localizedDescription }
    }

    func export() {
        guard let plan, let destinationParent else { return }
        step = .copy; isWorking = true; errorMessage = nil
        progressCompleted = 0; progressTotal = plan.items.count
        statusMessage = "Criando cópias e verificando SHA-256…"
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
                statusMessage = failures == 0 ? "Exportação concluída e verificada." : "Exportação concluída com \(failures) item(ns) para revisar."
            } catch is CancellationError {
                statusMessage = "Exportação cancelada. Cópias já verificadas foram preservadas."
            } catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }

    func cancel() { operationTask?.cancel() }

    func revealOutput() {
        if let outputURL { NSWorkspace.shared.activateFileViewerSelecting([outputURL]) }
    }

    private func contains(_ parent: URL, _ child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }
}
