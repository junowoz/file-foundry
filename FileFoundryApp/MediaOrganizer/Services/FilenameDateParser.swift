import Foundation

struct FilenameDateParser: Sendable {
    private let patterns = [
        #"(?<!\d)(20\d{2}|19\d{2})[-_]?([01]\d)[-_]?([0-3]\d)(?:[-_ T]?([0-2]\d)([0-5]\d)([0-5]\d))?(?!\d)"#
    ]

    func parse(_ filename: String) -> CaptureMoment? {
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) else { continue }
            func value(_ index: Int) -> Int? {
                guard index < match.numberOfRanges, match.range(at: index).location != NSNotFound,
                      let range = Range(match.range(at: index), in: filename) else { return nil }
                return Int(filename[range])
            }
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.year = value(1)
            components.month = value(2)
            components.day = value(3)
            components.hour = value(4)
            components.minute = value(5)
            components.second = value(6)
            guard let year = components.year, (1970...2100).contains(year),
                  let calendar = components.calendar,
                  let date = calendar.date(from: components) else { continue }
            let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            guard roundTrip.year == components.year,
                  roundTrip.month == components.month,
                  roundTrip.day == components.day,
                  roundTrip.hour == (components.hour ?? 0),
                  roundTrip.minute == (components.minute ?? 0),
                  roundTrip.second == (components.second ?? 0) else { continue }
            return CaptureMoment(components: components, source: .filenameHighConfidence, confidence: .high)
        }
        return nil
    }
}
