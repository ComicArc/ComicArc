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
            // Previously a distinctly navy-tinted, near-pitch-black (blue channel ran noticeably
            // ahead of red/green, more so at each lighter step, at a luminance so low the tint was
            // barely perceptible anyway). This is a decisively lighter, flatter charcoal -- still a
            // hair cooler than `graphite` so the two remain distinguishable -- with much wider
            // app/nav/card/surface steps so elevation actually reads at a glance instead of in
            // theory.
            return Palette(
                appBackground: Color(red: 0.075, green: 0.078, blue: 0.094),
                navBackground: Color(red: 0.105, green: 0.109, blue: 0.128),
                cardBg:        Color(red: 0.145, green: 0.150, blue: 0.172),
                surfaceBg:     Color(red: 0.188, green: 0.194, blue: 0.218),
                borderColor:   Color.white.opacity(0.16),
                brandBlue:     Color(red: 0.149, green: 0.396, blue: 0.733),
                brandGold:     Color(red: 0.918, green: 0.659, blue: 0.082)
            )
        case .pureBlack:
            return Palette(
                appBackground: .black,
                navBackground: Color(red: 0.035, green: 0.035, blue: 0.035),
                cardBg:        Color(red: 0.075, green: 0.075, blue: 0.075),
                surfaceBg:     Color(red: 0.115, green: 0.115, blue: 0.115),
                borderColor:   Color.white.opacity(0.13),
                brandBlue:     Color(red: 0.149, green: 0.396, blue: 0.733),
                brandGold:     Color(red: 0.918, green: 0.659, blue: 0.082)
            )
        case .graphite:
            return Palette(
                appBackground: Color(red: 0.145, green: 0.145, blue: 0.150),
                navBackground: Color(red: 0.175, green: 0.175, blue: 0.182),
                cardBg:        Color(red: 0.205, green: 0.205, blue: 0.213),
                surfaceBg:     Color(red: 0.235, green: 0.235, blue: 0.245),
                borderColor:   Color.white.opacity(0.14),
                brandBlue:     Color(red: 0.416, green: 0.647, blue: 0.902),
                brandGold:     Color(red: 0.87, green: 0.73, blue: 0.42)
            )
        case .midnightBlue:
            return Palette(
                appBackground: Color(red: 0.043, green: 0.090, blue: 0.220),
                navBackground: Color(red: 0.058, green: 0.110, blue: 0.260),
                cardBg:        Color(red: 0.075, green: 0.130, blue: 0.300),
                surfaceBg:     Color(red: 0.095, green: 0.155, blue: 0.340),
                borderColor:   Color(red: 0.5, green: 0.65, blue: 1.0).opacity(0.28),
                brandBlue:     Color(red: 0.478, green: 0.694, blue: 1.0),
                brandGold:     Color(red: 0.973, green: 0.741, blue: 0.184)
            )
        case .forest:
            return Palette(
                appBackground: Color(red: 0.035, green: 0.095, blue: 0.055),
                navBackground: Color(red: 0.048, green: 0.120, blue: 0.072),
                cardBg:        Color(red: 0.065, green: 0.150, blue: 0.095),
                surfaceBg:     Color(red: 0.085, green: 0.180, blue: 0.120),
                borderColor:   Color(red: 0.4, green: 0.85, blue: 0.55).opacity(0.20),
                brandBlue:     Color(red: 0.310, green: 0.671, blue: 0.478),
                brandGold:     Color(red: 0.906, green: 0.769, blue: 0.290)
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
