import Foundation

/// The newest stable item of a Sparkle appcast.
struct SparkleAppcastItem: Sendable, Equatable {
    let title: String?
    /// `sparkle:shortVersionString`, from the item or its enclosure.
    let shortVersion: String?
    /// `sparkle:version` (usually the build number), from the item or its enclosure.
    let version: String?
    /// Description as plain text, at most 2000 characters.
    let releaseNotes: String?
    let releaseNotesURL: URL?
    let pubDate: Date?
}

enum SparkleAppcastParser {
    static let maxNotesLength = 2000

    /// Returns the item with the latest pubDate (the first item when dates are missing or equal).
    /// Items marked with `sparkle:channel` (beta and other channels) are ignored.
    static func newestItem(in data: Data) -> SparkleAppcastItem? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items.max { lhs, rhs in
            (lhs.pubDate ?? .distantPast) < (rhs.pubDate ?? .distantPast)
        }
    }

    static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(p|li|h[1-6]|div)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(maxNotesLength))
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private struct Builder {
            var title: String?
            var shortVersion: String?
            var version: String?
            var notes: String?
            var notesURL: String?
            var pubDate: String?
            var isBeta = false
        }

        var items: [SparkleAppcastItem] = []
        private var builder: Builder?
        private var element = ""
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
            element = elementName
            text = ""
            if elementName == "item" {
                builder = Builder()
            } else if elementName == "enclosure", var current = builder {
                current.shortVersion = current.shortVersion ?? attributeDict["sparkle:shortVersionString"]
                current.version = current.version ?? attributeDict["sparkle:version"]
                builder = current
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            defer { text = "" }
            guard builder != nil else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "title": builder?.title = value
            case "pubDate": builder?.pubDate = value
            case "description": builder?.notes = value
            case "sparkle:releaseNotesLink": builder?.notesURL = value
            case "sparkle:shortVersionString": builder?.shortVersion = value
            case "sparkle:version": builder?.version = value
            case "sparkle:channel": builder?.isBeta = true
            case "item":
                let finished = builder
                builder = nil
                guard let finished, !finished.isBeta else { return }
                items.append(SparkleAppcastItem(
                    title: finished.title,
                    shortVersion: finished.shortVersion,
                    version: finished.version,
                    releaseNotes: finished.notes.map { SparkleAppcastParser.plainText(fromHTML: $0) },
                    releaseNotesURL: finished.notesURL.flatMap { URL(string: $0) },
                    pubDate: finished.pubDate.flatMap { SparkleAppcastParser.parseDate($0) }))
            default: break
            }
        }
    }
}
