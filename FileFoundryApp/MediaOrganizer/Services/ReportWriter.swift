import Foundation

struct ReportWriter {
    func write(manifest: ExportManifest, to root: DestinationRoot) throws {
        let policy = FileSystemPolicy()
        for relativePath in ["Relatórios/manifest.json", "Relatórios/relatorio.csv", "Relatórios/relatorio.md"] {
            _ = try policy.validatedDestination(relativePath: relativePath, in: root)
            try policy.validateDestinationAncestors(relativePath: relativePath, in: root)
        }
        let reports = root.url.appendingPathComponent("Relatórios", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try policy.validateDestinationAncestors(relativePath: "Relatórios/manifest.json", in: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: reports.appendingPathComponent("manifest.json"), options: .withoutOverwriting)

        let escaped: (String) -> String = Self.csvCell
        var csv = "source,destination,sha256,bytes,status,error\n"
        for record in manifest.records {
            csv += [record.sourceRelativePath, record.destinationRelativePath, record.sha256 ?? "", String(record.bytes), record.status.rawValue, record.error ?? ""].map(escaped).joined(separator: ",") + "\n"
        }
        try Data(csv.utf8).write(to: reports.appendingPathComponent("relatorio.csv"), options: .withoutOverwriting)

        let verified = manifest.records.filter { $0.status == .committedVerified }
        let failed = manifest.records.filter { $0.status == .failed }
        let markdown = """
        # Relatório File Foundry — Media Organizer

        - Operação: \(manifest.operationID.uuidString)
        - Arquivos verificados por SHA-256: \(verified.count)
        - Arquivos com falha: \(failed.count)
        - Bytes copiados e verificados: \(verified.reduce(0) { $0 + $1.bytes })
        - Template: `\(manifest.template)`

        \(failed.isEmpty ? "Exportação concluída sem falhas." : "Atenção: há itens que não foram exportados. Consulte o manifest JSON.")
        """
        try Data(markdown.utf8).write(to: reports.appendingPathComponent("relatorio.md"), options: .withoutOverwriting)
    }

    static func csvCell(_ value: String) -> String {
        let firstMeaningful = value.drop(while: { $0 == " " }).first
        let formulaPrefixes: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]
        let safeValue = firstMeaningful.map(formulaPrefixes.contains) == true ? "'" + value : value
        return "\"" + safeValue.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
