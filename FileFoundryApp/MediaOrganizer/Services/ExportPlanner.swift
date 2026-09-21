import Foundation

struct ExportPlanner: Sendable {
    private let templateEngine = TemplateEngine()

    func makePlan(summary: ScanSummary, sources: [SourceRoot], template: String) throws -> ExportPlan {
        try templateEngine.validate(template)
        let sourceNames = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.displayName) })
        let groupsByDuplicate = summary.duplicateGroups.reduce(into: [UUID: MediaDuplicateGroup]()) { result, group in
            for id in group.duplicateIDs { result[id] = group }
        }
        var usedPaths = Set<String>()
        var structuralConflictIndex = 1
        var items: [PlannedItem] = []
        let ordered = summary.exportableRecords.sorted { $0.sourceURL.path.localizedStandardCompare($1.sourceURL.path) == .orderedAscending }

        for record in ordered {
            let proposedDirectory: String
            let baseStatus: PlannedStatus
            let group = groupsByDuplicate[record.id]
            if let group {
                let prefix = String(group.hash.prefix(8)).uppercased()
                let groupIndex = (summary.duplicateGroups.firstIndex(where: { $0.id == group.id }) ?? 0) + 1
                proposedDirectory = String(format: "Duplicados Exatos/Grupo %06d - %@", groupIndex, prefix)
                baseStatus = .exactDuplicate
            } else if record.captureMoment == nil {
                proposedDirectory = "Sem Data/\(record.kind.folderName)"
                baseStatus = .undated
            } else if record.kind == .other || record.kind == .sidecar {
                proposedDirectory = record.kind == .sidecar ? "Outros/Sidecars" : "Outros"
                baseStatus = record.kind == .sidecar ? .sidecar : .other
            } else {
                proposedDirectory = try templateEngine.resolve(template, record: record, sourceFolder: sourceNames[record.sourceRootID] ?? "Origem")
                baseStatus = .copy
            }
            let original = "\(proposedDirectory)/\(record.filename)"
            let unique = uniquePath(original, used: &usedPaths, structuralConflictIndex: &structuralConflictIndex)
            let status: PlannedStatus = unique == original ? baseStatus : .renamedCollision
            items.append(PlannedItem(record: record, destinationRelativePath: unique, status: status, duplicateGroupID: group?.id))
        }
        return ExportPlan(operationID: UUID(), template: template, items: items)
    }

    private func uniquePath(_ path: String, used: inout Set<String>, structuralConflictIndex: inout Int) -> String {
        let key = normalized(path)
        if isReserved(key) || hasAncestorConflict(key, used: used) {
            return structuralFallback(for: path, used: &used, index: &structuralConflictIndex)
        }
        if used.insert(key).inserted { return path }
        let pathValue = path as NSString
        let directory = pathValue.deletingLastPathComponent
        let ext = pathValue.pathExtension
        let stem = (pathValue.lastPathComponent as NSString).deletingPathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let candidate = directory == "." ? name : "\(directory)/\(name)"
            if used.insert(normalized(candidate)).inserted { return candidate }
            index += 1
        }
    }

    private func structuralFallback(for path: String, used: inout Set<String>, index: inout Int) -> String {
        let filename = (path as NSString).lastPathComponent
        while true {
            let candidate = String(format: "Conflitos de Estrutura/Item %06d/%@", index, filename)
            index += 1
            let key = normalized(candidate)
            if !hasAncestorConflict(key, used: used), used.insert(key).inserted { return candidate }
        }
    }

    private func normalized(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func hasAncestorConflict(_ candidate: String, used: Set<String>) -> Bool {
        used.contains { existing in candidate.hasPrefix(existing + "/") || existing.hasPrefix(candidate + "/") }
    }

    private func isReserved(_ path: String) -> Bool {
        let reserved = ["relatórios", ".file-foundry-staging"]
        return reserved.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
