import Foundation

enum TemplateError: LocalizedError, Equatable {
    case empty
    case absolutePath
    case unsafeComponent(String)
    case unknownToken(String)
    case missingDate

    var errorDescription: String? {
        switch self {
        case .empty: "The template can't be empty."
        case .absolutePath: "The template must produce a relative path."
        case .unsafeComponent(let value): "Unsafe path component: \(value)"
        case .unknownToken(let token): "Unknown token: \(token)"
        case .missingDate: "This item has no reliable date."
        }
    }
}

struct TemplateEngine: Sendable {
    static let defaultTemplate = "{YYYY}/{MM} - {Month}"
    static let knownTokens: Set<String> = ["YYYY", "YY", "MM", "Month", "MonthShort", "DD", "MediaType", "Extension", "CameraMake", "CameraModel", "SourceFolder"]

    func validate(_ template: String) throws {
        guard !template.isEmpty else { throw TemplateError.empty }
        guard !template.hasPrefix("/"), !template.hasPrefix("~") else { throw TemplateError.absolutePath }
        let components = template.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in components {
            guard !component.isEmpty, component != ".", component != "..", component.utf8.count <= 240, !component.contains("\0"), !component.contains("\\") else {
                throw TemplateError.unsafeComponent(component)
            }
        }
        let regex = try NSRegularExpression(pattern: #"\{([^}]+)\}"#)
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(match.range(at: 1), in: template) else { continue }
            let token = String(template[range])
            guard Self.knownTokens.contains(token) else { throw TemplateError.unknownToken(token) }
        }
    }

    func resolve(_ template: String, record: MediaRecord, sourceFolder: String, locale: Locale = .current) throws -> String {
        try validate(template)
        guard let moment = record.captureMoment, let year = moment.year, let month = moment.month else { throw TemplateError.missingDate }
        let monthSymbols = Calendar(identifier: .gregorian).monthSymbols
        let shortSymbols = Calendar(identifier: .gregorian).shortMonthSymbols
        let localizedCalendar = configuredCalendar(locale: locale)
        let monthName = localizedCalendar.monthSymbols[month - 1].capitalized(with: locale)
        let shortName = localizedCalendar.shortMonthSymbols[month - 1].capitalized(with: locale).replacingOccurrences(of: ".", with: "")
        _ = monthSymbols; _ = shortSymbols
        let replacements: [String: String] = [
            "YYYY": String(format: "%04d", year),
            "YY": String(format: "%02d", year % 100),
            "MM": String(format: "%02d", month),
            "Month": monthName,
            "MonthShort": shortName,
            "DD": String(format: "%02d", moment.day ?? 1),
            "MediaType": safeToken(record.kind.folderName),
            "Extension": safeToken(record.sourceURL.pathExtension.lowercased().isEmpty ? "No extension" : record.sourceURL.pathExtension.lowercased()),
            "CameraMake": "Unknown",
            "CameraModel": "Unknown",
            "SourceFolder": safeToken(sourceFolder)
        ]
        var result = template
        for (token, value) in replacements { result = result.replacingOccurrences(of: "{\(token)}", with: value) }
        try validateResolved(result)
        return result
    }

    private func configuredCalendar(locale: Locale) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar
    }

    private func safeToken(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0")
        let pieces = value.components(separatedBy: forbidden).filter { !$0.isEmpty }
        let joined = pieces.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty || joined == "." || joined == ".." ? "Unknown" : String(joined.prefix(120))
    }

    private func validateResolved(_ path: String) throws {
        guard !path.hasPrefix("/") else { throw TemplateError.absolutePath }
        for component in path.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            guard !component.isEmpty, component != ".", component != "..", component.utf8.count <= 240,
                  !component.contains("\\"), !component.contains("\0") else { throw TemplateError.unsafeComponent(component) }
        }
    }
}
