import SwiftUI

// MARK: - Appearance themes
//
// Design's color tokens are `static` and read once — cheap, and every existing call site
// (Design.appBackground, Design.brandBlue, etc., used in dozens of files) keeps working
// unchanged. The tradeoff: a theme change takes effect on next launch rather than live,
// same as most apps that let you pick a genuinely different palette rather than just a
// system light/dark toggle. Settings makes that explicit rather than surprising.
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
            // True OLED black — every surface a hair lighter than the last so cards/sheets
            // still read as distinct layers even at zero luminance for the base background.
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
                brandBlue:     Color(red: 0.55, green: 0.56, blue: 0.58),
                brandGold:     Color(red: 0.85, green: 0.72, blue: 0.45)
            )
        case .midnightBlue:
            return Palette(
                appBackground: Color(red: 0.031, green: 0.043, blue: 0.086),
                navBackground: Color(red: 0.047, green: 0.063, blue: 0.114),
                cardBg:        Color(red: 0.067, green: 0.086, blue: 0.153),
                surfaceBg:     Color(red: 0.086, green: 0.110, blue: 0.192),
                borderColor:   Color.white.opacity(0.10),
                brandBlue:     Color(red: 0.353, green: 0.541, blue: 0.941),
                brandGold:     Color(red: 0.918, green: 0.659, blue: 0.082)
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
            // The one light theme — warm parchment tones for anyone who finds a pure-dark
            // reader uncomfortable, rather than assuming everyone wants black.
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

    /// True for the one light palette — drives which SwiftUI color scheme the app forces.
    var isLight: Bool { self == .sepia }
}
