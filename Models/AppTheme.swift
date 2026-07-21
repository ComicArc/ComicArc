import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case dark, pureBlack, graphite, midnightBlue, forest, sepia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark:         return "Dark (Default)"
        case .pureBlack:    return "Pure Black (OLED)"
        case .graphite:     return "Graphite"
        case .midnightBlue: return "Midnight Blue"
        case .forest:       return "Forest"
        case .sepia:        return "Sepia"
        }
    }

    struct Palette {
        let appBackground: Color
        let navBackground: Color
        let cardBg: Color
        let surfaceBg: Color
        let borderColor: Color
        let brandBlue: Color
        let brandGold: Color
    }

    var palette: Palette {
        switch self {
        case .dark:
            return Palette(
                appBackground: Color(red: 0.046, green: 0.048, blue: 0.074),
                navBackground: Color(red: 0.065, green: 0.068, blue: 0.102),
                cardBg:        Color(red: 0.088, green: 0.092, blue: 0.132),
                surfaceBg:     Color(red: 0.108, green: 0.114, blue: 0.162),
                borderColor:   Color.white.opacity(0.09),
                brandBlue:     Color(red: 0.149, green: 0.396, blue: 0.733),
                brandGold:     Color(red: 0.918, green: 0.659, blue: 0.082)
            )
        case .pureBlack:

            return Palette(
                appBackground: .black,
                navBackground: Color(red: 0.03, green: 0.03, blue: 0.03),
                cardBg:        Color(red: 0.06, green: 0.06, blue: 0.06),
                surfaceBg:     Color(red: 0.09, green: 0.09, blue: 0.09),
                borderColor:   Color.white.opacity(0.10),
                brandBlue:     Color(red: 0.149, green: 0.396, blue: 0.733),
                brandGold:     Color(red: 0.918, green: 0.659, blue: 0.082)
            )
        case .graphite:
            return Palette(
                appBackground: Color(red: 0.075, green: 0.075, blue: 0.078),
                navBackground: Color(red: 0.100, green: 0.100, blue: 0.104),
                cardBg:        Color(red: 0.130, green: 0.130, blue: 0.135),
                surfaceBg:     Color(red: 0.160, green: 0.160, blue: 0.166),
                borderColor:   Color.white.opacity(0.08),
                brandBlue:     Color(red: 0.416, green: 0.647, blue: 0.902),
                brandGold:     Color(red: 0.87, green: 0.73, blue: 0.42)
            )
        case .midnightBlue:
            return Palette(
                appBackground: Color(red: 0.024, green: 0.035, blue: 0.098),
                navBackground: Color(red: 0.039, green: 0.055, blue: 0.145),
                cardBg:        Color(red: 0.055, green: 0.078, blue: 0.196),
                surfaceBg:     Color(red: 0.075, green: 0.102, blue: 0.243),
                borderColor:   Color(red: 0.4, green: 0.55, blue: 0.95).opacity(0.22),
                brandBlue:     Color(red: 0.396, green: 0.616, blue: 0.980),
                brandGold:     Color(red: 0.949, green: 0.694, blue: 0.129)
            )
        case .forest:
            return Palette(
                appBackground: Color(red: 0.043, green: 0.063, blue: 0.051),
                navBackground: Color(red: 0.059, green: 0.086, blue: 0.070),
                cardBg:        Color(red: 0.082, green: 0.114, blue: 0.094),
                surfaceBg:     Color(red: 0.106, green: 0.145, blue: 0.121),
                borderColor:   Color.white.opacity(0.09),
                brandBlue:     Color(red: 0.310, green: 0.671, blue: 0.478),
                brandGold:     Color(red: 0.851, green: 0.714, blue: 0.263)
            )
        case .sepia:

            return Palette(
                appBackground: Color(red: 0.949, green: 0.918, blue: 0.851),
                navBackground: Color(red: 0.925, green: 0.890, blue: 0.812),
                cardBg:        Color(red: 0.984, green: 0.965, blue: 0.918),
                surfaceBg:     Color(red: 0.898, green: 0.859, blue: 0.773),
                borderColor:   Color.black.opacity(0.12),
                brandBlue:     Color(red: 0.290, green: 0.204, blue: 0.106),
                brandGold:     Color(red: 0.686, green: 0.482, blue: 0.129)
            )
        }
    }

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .dark
    }

    var isLight: Bool { self == .sepia }
}
