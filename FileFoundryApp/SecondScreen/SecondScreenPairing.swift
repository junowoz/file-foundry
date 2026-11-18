import Foundation
import Security

/// Pairing code: 12 characters from an alphabet without look-alikes (≈59 bits).
enum SSPairingCode {
    static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
    static let length = 12
    static let lifetime: TimeInterval = 120
    static let maxAttempts = 5

    static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    static func generate<R: RandomNumberGenerator>(using rng: inout R) -> String {
        String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }

    static func isValid(_ code: String) -> Bool {
        code.count == length && code.allSatisfy { alphabet.contains($0) }
    }

    /// "ABCD-2345-EFGH" for display only; the secret is always the 12 characters without dashes.
    static func display(_ code: String) -> String {
        guard code.count == length else { return code }
        let chars = Array(code)
        return stride(from: 0, to: length, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }
}

/// The current code with its expiry, attempt budget and the wrong-proof back-off.
struct SSPairingState: Sendable, Equatable {
    private(set) var code: String
    private(set) var expiresAt: Date
    private(set) var failedAttempts = 0
    /// Wrong proofs since the last successful pairing (survives code rotation, so rotating cannot reset the delay).
    private(set) var consecutiveFailures = 0
    private(set) var blockedUntil: Date = .distantPast

    init(code: String = SSPairingCode.generate(), now: Date = Date()) {
        self.code = code
        self.expiresAt = now.addingTimeInterval(SSPairingCode.lifetime)
    }

    func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }

    /// While true, pairing attempts are refused without being evaluated.
    func isBlocked(now: Date = Date()) -> Bool { now < blockedUntil }

    /// Delay after the n-th consecutive wrong proof: 2, 4, 8, … capped at 60 s.
    static func backoff(afterFailures n: Int) -> TimeInterval {
        min(60, pow(2, Double(min(max(n, 1), 10))))
    }

    /// Count a failed proof and start the back-off. Returns true when the code must be replaced.
    mutating func registerFailure(now: Date = Date()) -> Bool {
        failedAttempts += 1
        consecutiveFailures += 1
        blockedUntil = now.addingTimeInterval(Self.backoff(afterFailures: consecutiveFailures))
        return failedAttempts >= SSPairingCode.maxAttempts
    }

    /// A successful pairing clears the back-off.
    mutating func registerSuccess() {
        consecutiveFailures = 0
        blockedUntil = .distantPast
    }

    mutating func regenerate(now: Date = Date()) {
        var next = SSPairingState(now: now)
        next.consecutiveFailures = consecutiveFailures
        next.blockedUntil = blockedUntil
        self = next
    }
}

// MARK: - Paired devices

struct SSPairedDevice: Identifiable, Equatable, Sendable {
    var id: String          // deviceId
    var name: String
    var pairedAt: Date
}

protocol SSDeviceKeyStore: Sendable {
    func key(for deviceId: String) -> Data?
    func save(key: Data, deviceId: String, name: String) throws
    func forget(deviceId: String)
    func devices() -> [SSPairedDevice]
    /// Random UUID created once and kept; clients store keys per host id.
    func hostId() -> String
}

/// Keychain-backed store (data protection keychain, this device only, not synchronizable):
/// one generic password per deviceId plus one item for the host id.
struct SSKeychainKeyStore: SSDeviceKeyStore {
    static let service = "com.junowoz.filefoundry.secondscreen"
    static let hostIdAccount = "host-id"

    /// Process-wide fallback so the id stays stable for the run even if the Keychain refuses (unsigned builds).
    private static let fallbackHostId = LockedBox<String>(nil)

    static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func key(for deviceId: String) -> Data? { read(deviceId) }

    private func read(_ account: String) -> Data? {
        var q = Self.baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// Update in place; add only when the item does not exist. Never delete-then-add.
    private func write(_ data: Data, account: String, label: String) throws {
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        var status = SecItemUpdate(Self.baseQuery(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var q = Self.baseQuery(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = label
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func save(key: Data, deviceId: String, name: String) throws {
        try write(key, account: deviceId, label: name)
    }

    func forget(deviceId: String) { SecItemDelete(Self.baseQuery(deviceId) as CFDictionary) }

    func hostId() -> String {
        if let data = read(Self.hostIdAccount), let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil {
            return id
        }
        if let cached = Self.fallbackHostId.value { return cached }
        let id = UUID().uuidString
        if (try? write(Data(id.utf8), account: Self.hostIdAccount, label: "File Foundry host id")) == nil {
            Self.fallbackHostId.value = id
        }
        return id
    }

    func devices() -> [SSPairedDevice] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Self.service,
                                kSecAttrSynchronizable as String: false,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        q[kSecReturnData as String] = false
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row[kSecAttrAccount as String] as? String, id != Self.hostIdAccount else { return nil }
            return SSPairedDevice(id: id,
                                  name: (row[kSecAttrLabel as String] as? String) ?? "Android device",
                                  pairedAt: (row[kSecAttrCreationDate as String] as? Date) ?? .distantPast)
        }.sorted { $0.pairedAt > $1.pairedAt }
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    init(_ value: T?) { _value = value }
    var value: T? { get { lock.withLock { _value } } set { lock.withLock { _value = newValue } } }
}

/// In-memory store for tests.
final class SSMemoryKeyStore: SSDeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (Data, String, Date)] = [:]

    func key(for deviceId: String) -> Data? { lock.withLock { items[deviceId]?.0 } }
    func save(key: Data, deviceId: String, name: String) throws { lock.withLock { items[deviceId] = (key, name, Date()) } }
    func forget(deviceId: String) { lock.withLock { items[deviceId] = nil } }
    private let id = UUID().uuidString
    func hostId() -> String { id }
    func devices() -> [SSPairedDevice] {
        lock.withLock { items.map { SSPairedDevice(id: $0.key, name: $0.value.1, pairedAt: $0.value.2) } }
    }
}
