import Foundation

public struct AppSettingsService {
    private let defaults: UserDefaults
    private let key = "FileFoundry.AppSettings"
    private let legacyKey = "Doppel.AppSettings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) ?? defaults.data(forKey: legacyKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: key)
    }
}
