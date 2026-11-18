import Foundation

struct VolumeInfo: Sendable, Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let url: URL
    let total: Int64
    let available: Int64
    /// Free space including purgeable data macOS can reclaim on demand.
    let availableForImportantUsage: Int64
    let isExternal: Bool

    var purgeable: Int64 { max(0, availableForImportantUsage - available) }
    var used: Int64 { max(0, total - available) }

    /// "/" first, then mounted external volumes.
    static func all() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [VolumeInfo] = []
        for u in urls where u.path == "/" || u.path.hasPrefix("/Volumes/") {
            if let v = info(for: u) { out.append(v) }
        }
        if !out.contains(where: { $0.url.path == "/" }), let root = info(for: URL(fileURLWithPath: "/")) { out.insert(root, at: 0) }
        return out.sorted { ($0.url.path == "/" ? 0 : 1, $0.name) < ($1.url.path == "/" ? 0 : 1, $1.name) }
    }

    static func info(for url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey]),
              let total = v.volumeTotalCapacity else { return nil }
        let avail = Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeInfo(name: v.volumeName ?? url.lastPathComponent, url: url, total: Int64(total), available: avail,
                          availableForImportantUsage: v.volumeAvailableCapacityForImportantUsage ?? avail,
                          isExternal: url.path != "/" && v.volumeIsInternal != true)
    }
}
