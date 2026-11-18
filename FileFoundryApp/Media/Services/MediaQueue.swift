import Foundation

struct MediaItem: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case probing
        case ready
        case queued
        case running(progress: Double?, label: String, eta: TimeInterval?)
        case done(CompressionResult)
        case failed(String)
    }

    let id: UUID
    let url: URL
    var info = MediaInfo.other
    var originalBytes = 0
    var state = State.probing

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
    }

    var kind: ContentKind { info.kind }
    var isRunning: Bool { if case .running = state { true } else { false } }
    var isQueued: Bool { state == .queued }
    var isActive: Bool { isRunning || isQueued }
    var isFinished: Bool {
        switch state { case .done, .failed: true; default: false }
    }
    var isIdle: Bool { state == .ready }
}

/// Pure queue state. The model drives it; tests exercise every transition without touching ffmpeg.
struct MediaQueue: Equatable, Sendable {
    private(set) var items: [MediaItem] = []

    var isEmpty: Bool { items.isEmpty }
    var isBusy: Bool { items.contains { $0.isActive } }
    var isProbing: Bool { items.contains { $0.state == .probing } }
    var hasFinished: Bool { items.contains { $0.isFinished } }
    /// Items a Start press would process: ready ones and failed ones (retry).
    var startableCount: Int { items.filter { $0.isIdle || isFailed($0) }.count }
    var doneCount: Int { items.filter { if case .done = $0.state { true } else { false } }.count }

    /// Kinds present, in stable display order.
    var kinds: [ContentKind] {
        Set(items.filter { $0.state != .probing }.map(\.kind)).sorted { $0.sortOrder < $1.sortOrder }
    }

    func items(of kind: ContentKind) -> [MediaItem] { items.filter { $0.kind == kind && $0.state != .probing } }
    func item(_ id: UUID) -> MediaItem? { items.first { $0.id == id } }

    private func isFailed(_ item: MediaItem) -> Bool { if case .failed = item.state { true } else { false } }

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    /// Adds new files in `.probing` state. Files already in the queue are skipped. Returns what was added.
    @discardableResult
    mutating func add(_ urls: [URL]) -> [MediaItem] {
        var existing = Set(items.map { $0.url.standardizedFileURL.path })
        var added: [MediaItem] = []
        for url in urls {
            let url = url.standardizedFileURL
            guard existing.insert(url.path).inserted else { continue }
            added.append(MediaItem(url: url))
        }
        items += added
        return added
    }

    mutating func setProbed(_ id: UUID, info: MediaInfo, bytes: Int) {
        guard let i = index(id), items[i].state == .probing else { return }
        items[i].info = info
        items[i].originalBytes = bytes
        items[i].state = .ready
    }

    /// ready and failed items become queued. Returns how many.
    @discardableResult
    mutating func enqueue() -> Int {
        var count = 0
        for i in items.indices where items[i].isIdle || isFailed(items[i]) {
            items[i].state = .queued
            count += 1
        }
        return count
    }

    /// The next queued item, only when nothing is running (one encode at a time).
    func nextQueued() -> MediaItem? {
        guard !items.contains(where: \.isRunning) else { return nil }
        return items.first { $0.isQueued }
    }

    mutating func markRunning(_ id: UUID, label: String) {
        guard let i = index(id), items[i].isQueued else { return }
        items[i].state = .running(progress: 0, label: label, eta: nil)
    }

    mutating func updateProgress(_ id: UUID, progress: Double?, label: String, eta: TimeInterval?) {
        guard let i = index(id), items[i].isRunning else { return }
        items[i].state = .running(progress: progress, label: label, eta: eta)
    }

    mutating func finish(_ id: UUID, result: CompressionResult) {
        guard let i = index(id), items[i].isRunning else { return }
        items[i].state = .done(result)
    }

    /// Fails a queued or running item.
    mutating func fail(_ id: UUID, message: String) {
        guard let i = index(id), items[i].isActive else { return }
        items[i].state = .failed(message)
    }

    /// Stops everything: running and queued items go back to ready.
    mutating func cancelAll() {
        for i in items.indices where items[i].isActive { items[i].state = .ready }
    }

    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    mutating func clearFinished() { items.removeAll { $0.isFinished } }

    mutating func removeAll() { items.removeAll() }
}
