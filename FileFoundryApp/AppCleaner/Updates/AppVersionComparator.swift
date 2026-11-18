import Foundation

enum AppVersionComparator {
    /// Compares dotted numeric versions, so "1.10" is newer than "1.9".
    /// Missing components count as 0. Each component reads its leading digits only ("3-beta" is 3).
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    private static func components(_ version: String) -> [Int] {
        version.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { part in
                let digits = part.prefix { $0.isASCII && $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}
