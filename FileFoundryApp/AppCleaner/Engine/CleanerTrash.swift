import Foundation

struct TrashItemRecord: Codable, Sendable, Hashable {
    let originalPath: String
    /// Where the item landed in the Trash; nil when the system did not report it (cannot be put back automatically).
    let trashPath: String?
    let size: Int64
}

struct TrashRecord: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let label: String
    var items: [TrashItemRecord]
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

enum RemovalStatus: Sendable, Equatable {
    case trashed(trashURL: URL?)
    case blocked(SafetyVerdict)
    case failed(String)
    case cancelled
}

struct ItemOutcome: Sendable, Equatable {
    let url: URL
    let status: RemovalStatus
    var succeeded: Bool { if case .trashed = status { true } else { false } }
}

struct RemovalReport: Sendable {
    let outcomes: [ItemOutcome]
    /// nil when nothing was moved to the Trash.
    let record: TrashRecord?
    var freedBytes: Int64 { record?.totalSize ?? 0 }
    var failures: [ItemOutcome] { outcomes.filter { !$0.succeeded } }
    var isCompleteSuccess: Bool { failures.isEmpty }
}

struct PutBackFailure: Sendable, Equatable { let originalPath: String; let reason: String }

struct PutBackReport: Sendable {
    let restored: [URL]
    let failures: [PutBackFailure]
}

/// Recoverable removal: everything goes to the Trash (never removeItem) and is logged so it can be put back.
actor CleanerTrash {
    static let maxRecords = 100
    private let env: CleanerEnvironment
    private var records: [TrashRecord]

    init(env: CleanerEnvironment) {
        self.env = env
        self.records = Self.load(env.historyURL)
    }

    /// Newest first.
    func history() -> [TrashRecord] { records }

    func remove(_ items: [CleanupItem], label: String) async -> RemovalReport {
        await remove(items.map(\.removalRequest), label: label)
    }

    /// Per-item results; one failure never aborts the rest. Quit apps and unsafe paths are reported, not touched.
    func remove(_ requests: [RemovalRequest], label: String) async -> RemovalReport {
        var outcomes: [ItemOutcome] = []
        var recorded: [TrashItemRecord] = []
        for req in requests {
            if Task.isCancelled { outcomes.append(ItemOutcome(url: req.url, status: .cancelled)); continue }
            let verdict = CleanerSafety.check(req.url, env: env)
            guard verdict.isAllowed else { outcomes.append(ItemOutcome(url: req.url, status: .blocked(verdict))); continue }
            do {
                let trashURL = req.needsAdmin ? try await env.recycle(req.url) : try env.trash(req.url)
                recorded.append(TrashItemRecord(originalPath: req.url.path, trashPath: trashURL?.path, size: req.size))
                outcomes.append(ItemOutcome(url: req.url, status: .trashed(trashURL: trashURL)))
            } catch {
                outcomes.append(ItemOutcome(url: req.url, status: .failed(error.localizedDescription)))
            }
        }
        var record: TrashRecord?
        if !recorded.isEmpty {
            let r = TrashRecord(id: UUID(), date: Date(), label: label, items: recorded)
            records.insert(r, at: 0)
            if records.count > Self.maxRecords { records = Array(records.prefix(Self.maxRecords)) }
            save()
            record = r
        }
        return RemovalReport(outcomes: outcomes, record: record)
    }

    /// Moves each item back when its Trash copy still exists and the original path is free.
    func putBack(_ record: TrashRecord) -> PutBackReport {
        let fm = FileManager.default
        let trashRoots = env.trashRoots.map(CleanerPaths.real)
        var restored: [URL] = []
        var failures: [PutBackFailure] = []
        var remaining: [TrashItemRecord] = []
        let current = records.first(where: { $0.id == record.id })?.items ?? record.items
        for item in current {
            func fail(_ reason: String) { failures.append(PutBackFailure(originalPath: item.originalPath, reason: reason)); remaining.append(item) }
            guard let tp = item.trashPath else { fail("The system did not report where the item went in the Trash."); continue }
            let trashURL = URL(fileURLWithPath: tp), original = URL(fileURLWithPath: item.originalPath)
            let realTrash = CleanerPaths.real(trashURL)
            guard trashRoots.contains(where: { CleanerPaths.isInside(realTrash, $0) }) else { fail("The recorded Trash path is not inside the Trash."); continue }
            guard (try? fm.attributesOfItem(atPath: tp)) != nil else { fail("The item is no longer in the Trash."); continue }
            guard (try? fm.attributesOfItem(atPath: item.originalPath)) == nil else { fail("Something already exists at the original location."); continue }
            if case .refused(let why) = CleanerSafety.check(original, env: env) { fail(why.message); continue }
            do {
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: trashURL, to: original)
                restored.append(original)
            } catch {
                fail(error.localizedDescription)
            }
        }
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            if remaining.isEmpty { records.remove(at: idx) } else { records[idx].items = remaining }
            save()
        }
        return PutBackReport(restored: restored, failures: failures)
    }

    func forget(_ record: TrashRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    private static func load(_ url: URL) -> [TrashRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode([TrashRecord].self, from: data)) ?? []
    }

    private func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(records) else { return }
        try? FileManager.default.createDirectory(at: env.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: env.historyURL, options: .atomic)
    }
}
