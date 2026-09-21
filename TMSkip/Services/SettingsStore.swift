import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings

    private let defaultsKey = "tmskip.settings.v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? decoder.decode(AppSettings.self, from: data) {
            settings = Self.migrate(decoded)
            // Persist repairs so the stored copy matches what the UI shows.
            if settings != decoded {
                persist()
            }
        } else {
            settings = Self.migrate(AppSettings())
        }
    }

    /// Best-effort migration for older settings plus normalization of stored
    /// values, so every persisted copy already satisfies the invariants.
    private static func migrate(_ settings: AppSettings) -> AppSettings {
        var s = settings
        // Ensure at least home root exists for MVP.
        if s.roots.isEmpty {
            s.roots = [.home]
        }
        // Empty/corrupt rules → force bundled fallback.
        if s.rulePackage.rules.isEmpty {
            s.rulePackage = .bundledSnapshot
        }
        // Repair skip paths (full-width tilde, stray whitespace, trailing
        // slashes) that could never match the paths the scanner walks.
        s.skipPaths = s.skipPaths.map { AppSettings.normalizeSkipPath($0) }
        return s
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
        persist()
    }

    func replace(_ newValue: AppSettings) {
        settings = newValue
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
