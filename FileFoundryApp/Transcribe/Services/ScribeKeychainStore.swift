import Foundation
import Security

/// Stores the AssemblyAI key under File Foundry's own Keychain service.
/// The key is never logged or printed. The old Meeting Scribe item is read once and copied.
enum ScribeKeychainStore {
    static let service = "com.junowoz.filefoundry.transcribe"
    static let legacyService = "com.junowoz.MeetingScribe"
    static let account = "assemblyai-api-key"
    private static let migrationKey = "transcribe.keychain-migration-complete"

    static func saveAPIKey(_ value: String) throws {
        try save(value, service: service)
    }

    /// Attributes shared by every query so save, load and delete address the same item.
    static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    static func addQuery(service: String, data: Data) -> [String: Any] {
        var item = baseQuery(service: service)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return item
    }

    static func updateAttributes(data: Data) -> [String: Any] {
        [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }

    /// Update-or-add, never delete-then-add: a failure can't leave the user without a key. An empty value deletes.
    static func save(_ value: String, service: String) throws {
        let query = baseQuery(service: service)
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, updateAttributes(data: data) as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(addQuery(service: service, data: data) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// Reads the File Foundry item. If it is missing and the legacy item has not been checked yet,
    /// reads the Meeting Scribe item once and re-saves it under the new service.
    static func loadAPIKey(defaults: UserDefaults = .standard) -> String {
        let current = load(service: service).value
        guard current.isEmpty, !defaults.bool(forKey: migrationKey) else { return current }
        let legacy = load(service: legacyService)
        switch legacy.status {
        case errSecSuccess where !legacy.value.isEmpty:
            guard (try? save(legacy.value, service: service)) != nil else { return legacy.value }
            defaults.set(true, forKey: migrationKey)
            return legacy.value
        case errSecItemNotFound:
            defaults.set(true, forKey: migrationKey)
            return ""
        default:
            // Access was denied or cancelled: try again on a later launch.
            return ""
        }
    }

    private static func load(service: String) -> (value: String, status: OSStatus) {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return ("", status) }
        return (String(decoding: data, as: UTF8.self), status)
    }

    enum KeychainError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            switch self { case .status(let value): "Não foi possível salvar a chave no Keychain (\(value))." }
        }
    }
}
