import Foundation

/// Encode/decode helper for the list of configured library folders -- JSON, not comma-joined,
/// since Unix paths can legally contain commas (unlike `SidebarCustomization`'s comma-joined
/// enum-case lists, where that's safe).
enum LibraryFolders {
    static let key = "libraryPathsJSON"

    /// The pre-multi-folder single-path key. Kept around only so `decode`/`OnboardingGate` can
    /// migrate an existing install's one configured folder into the new array the first time it
    /// runs, without forcing the user back through onboarding.
    static let legacySingleKey = "libraryPath"

    static func decode(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return decoded
    }

    static func encode(_ paths: [String]) -> String {
        guard let data = try? JSONEncoder().encode(paths),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    /// Reads the current folder list, transparently migrating a pre-existing single `libraryPath`
    /// value the first time this runs on an already-installed library -- without this, updating
    /// to multi-folder support would silently wipe an existing user's configured folder and force
    /// them back through onboarding. `defaults` is injectable (defaulting to `.standard` for real
    /// use) so tests can exercise the migration against an isolated suite instead of the real
    /// app's actual UserDefaults.
    static func readMigrating(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: key) ?? ""
        let decoded = decode(raw)
        guard decoded.isEmpty else { return decoded }
        guard let legacy = defaults.string(forKey: legacySingleKey), !legacy.isEmpty else { return [] }
        let migrated = [legacy]
        defaults.set(encode(migrated), forKey: key)
        return migrated
    }

    static func write(_ paths: [String], defaults: UserDefaults = .standard) {
        defaults.set(encode(paths), forKey: key)
    }
}
