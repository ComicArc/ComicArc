import SwiftUI
import Observation

/// A complete color set for the app's chrome. Covers are the only other color.
struct Palette: Sendable {
    let background, sidebar, surface, raised: Color
    let accent, accentDeep: Color
    /// Text/icons drawn on top of the accent (e.g. the primary button label).
    let onAccent: Color
    let ink: Color          // base text color; secondary/tertiary are derived
    let scheme: ColorScheme
}

enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, forest, ocean, ember
    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var palette: Palette {
        switch self {
        case .dark:
            Palette(background: Color(hex: 0x141416), sidebar: Color(hex: 0x19191C), surface: Color(hex: 0x1F1F23),
                    raised: Color(hex: 0x29292E), accent: Color(hex: 0xF4B940), accentDeep: Color(hex: 0xD9952B),
                    onAccent: .black, ink: .white, scheme: .dark)
        case .light:
            Palette(background: Color(hex: 0xF6F4EF), sidebar: Color(hex: 0xECE9E2), surface: Color(hex: 0xFFFFFF),
                    raised: Color(hex: 0xE6E2D9), accent: Color(hex: 0xD48A12), accentDeep: Color(hex: 0xB86F05),
                    onAccent: .white, ink: Color(hex: 0x1C1B19), scheme: .light)
        case .forest:
            Palette(background: Color(hex: 0x111A15), sidebar: Color(hex: 0x15201A), surface: Color(hex: 0x1B2921),
                    raised: Color(hex: 0x24352B), accent: Color(hex: 0x8FD19E), accentDeep: Color(hex: 0x5FAF73),
                    onAccent: Color(hex: 0x0E1A12), ink: Color(hex: 0xEEF5EF), scheme: .dark)
        case .ocean:
            Palette(background: Color(hex: 0x0E1621), sidebar: Color(hex: 0x111B28), surface: Color(hex: 0x172434),
                    raised: Color(hex: 0x203043), accent: Color(hex: 0x5CCFE6), accentDeep: Color(hex: 0x2FA6C4),
                    onAccent: Color(hex: 0x07202A), ink: Color(hex: 0xEDF4FA), scheme: .dark)
        case .ember:
            Palette(background: Color(hex: 0x181311), sidebar: Color(hex: 0x1D1714), surface: Color(hex: 0x261E1A),
                    raised: Color(hex: 0x332822), accent: Color(hex: 0xFF8A4C), accentDeep: Color(hex: 0xE0632A),
                    onAccent: .black, ink: Color(hex: 0xF7EEE9), scheme: .dark)
        }
    }
}

/// The selected theme. Views that read `Theme` colors redraw when it changes.
@MainActor @Observable
final class ThemeStore {
    static let shared = ThemeStore()
    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Prefs.theme) }
    }
    private init() { theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: Prefs.theme) ?? "") ?? .dark }
}

/// Colors and metrics for the app chrome, drawn from the current theme.
@MainActor
enum Theme {
    private static var p: Palette { ThemeStore.shared.theme.palette }

    static var background: Color { p.background }
    static var sidebar: Color { p.sidebar }
    static var surface: Color { p.surface }
    static var raised: Color { p.raised }
    static var border: Color { p.ink.opacity(0.09) }
    static var hairline: Color { p.ink.opacity(0.05) }

    static var accent: Color { p.accent }
    static var accentDeep: Color { p.accentDeep }
    static var onAccent: Color { p.onAccent }
    static var accentGradient: LinearGradient { LinearGradient(colors: [p.accent, p.accentDeep], startPoint: .top, endPoint: .bottom) }
    static let finished = Color(hex: 0x4CC38A)
    static let danger = Color(hex: 0xF06464)

    static var textPrimary: Color { p.ink.opacity(0.94) }
    static var textSecondary: Color { p.ink.opacity(0.62) }
    static var textTertiary: Color { p.ink.opacity(0.42) }
    static var scheme: ColorScheme { p.scheme }

    static let corner: CGFloat = 8
    static let cardCorner: CGFloat = 6
    static let gutter: CGFloat = 28

    nonisolated static func publisherColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "dc": return Color(hex: 0x2F7DF6)
        case "marvel": return Color(hex: 0xE8343B)
        case "image": return Color(hex: 0x9B9BA3)
        case "dark horse": return Color(hex: 0x7C8B9C)
        case "idw": return Color(hex: 0x3BA5A0)
        case "boom!": return Color(hex: 0xF07C2E)
        default:
            // Stable across launches (String.hashValue is randomized per process).
            let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
            return Color(hue: hue, saturation: 0.5, brightness: 0.75)
        }
    }
}

extension Font {
    /// Kerned, heavy all-caps signage for section and screen titles.
    static func signage(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
