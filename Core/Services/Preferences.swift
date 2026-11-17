import Foundation

/// UserDefaults keys. Names match earlier versions where the setting already existed, so existing
/// preferences carry over.
enum Prefs {
    static let libraryFolders = "libraryPathsJSON"
    static let legacyLibraryFolder = "libraryPath"
    static let onboardingDone = "onboardingFinished"
    static let gridDensity = "gridDensity"
    static let sortOrder = "librarySortOrder"
    static let hideFinished = "hideFinished"
    static let colorFilter = "readerColorFilter"
    static let autoplaySeconds = "autoplaySpeed"
    static let defaultScrollMode = "scrollMode"
    static let comicInfoWriteBack = "comicInfoWriteBackEnabled"
    static let windowFrame = "mainWindowFrame"
    static let spotlightVersion = "spotlightIndexVersion"
    static let theme = "appTheme"
}

enum LibraryFolders {
    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        if let json = defaults.string(forKey: Prefs.libraryFolders),
           let paths = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
            return paths
        }
        if let legacy = defaults.string(forKey: Prefs.legacyLibraryFolder), !legacy.isEmpty { return [legacy] }
        return []
    }

    static func save(_ paths: [String], _ defaults: UserDefaults = .standard) {
        var unique: [String] = []
        for p in paths where !unique.contains(p) { unique.append(p) }
        let json = (try? JSONEncoder().encode(unique)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        defaults.set(json, forKey: Prefs.libraryFolders)
    }
}

enum GridDensity: String, CaseIterable, Identifiable {
    case compact, regular, large
    var id: String { rawValue }
    var cardWidth: CGFloat { switch self { case .compact: 128; case .regular: 168; case .large: 216 } }
    var spacing: CGFloat { switch self { case .compact: 16; case .regular: 22; case .large: 28 } }
    var label: String { rawValue.capitalized }
}
