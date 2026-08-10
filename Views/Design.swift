import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    func toHexString() -> String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        #if os(macOS)
        guard let rgb = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        r = rgb.redComponent; g = rgb.greenComponent; b = rgb.blueComponent
        #else
        var a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// HSB-clamps a cover-derived color into a specific saturation/brightness band -- shared by
    /// every "cover color drives a background/wash/scrim" use case below, since an unclamped
    /// cover average can be near-black, neon-saturated, or near-white, any of which looks broken
    /// stretched across something bigger than a small swatch. Named presets below pick the band;
    /// this just does the one HSB extraction they all need.
    func clamped(saturation: ClosedRange<Double>, brightness: ClosedRange<Double>) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        guard let c = NSColor(self).usingColorSpace(.deviceRGB) else { return self }
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #endif
        let clampedS = min(max(Double(s), saturation.lowerBound), saturation.upperBound)
        let clampedB = min(max(Double(b), brightness.lowerBound), brightness.upperBound)
        return Color(hue: Double(h), saturation: clampedS, brightness: clampedB)
    }

    /// For a whole background/header wash -- bright and saturated enough to read as deliberate
    /// atmosphere rather than a barely-there tint.
    func clampedForAtmosphere() -> Color { clamped(saturation: 0.30...0.65, brightness: 0.30...0.70) }

    /// Much darker/lower-saturation than `clampedForAtmosphere()` -- for the reader's near-black
    /// backdrop, which should read as "a hint of this cover's color in the dark," not an actual
    /// colored background competing with the page art itself.
    func clampedForDeepBackdrop() -> Color { clamped(saturation: 0.25...0.45, brightness: 0.05...0.12) }

    /// Between the two above -- dark enough that white overlaid text (a `GroupCard`'s title, e.g.)
    /// stays legible, but visibly colored rather than reading as the plain black scrim it replaces.
    func clampedForScrim() -> Color { clamped(saturation: 0.35...0.60, brightness: 0.14...0.30) }

    /// Readable label color for text/icons drawn over this color used as a background wash --
    /// computed from perceptual luminance rather than the app's light/dark theme, since a tint's
    /// own brightness can land either way regardless of which theme is active.
    var readableForeground: Color {
        var r: CGFloat = 0, g: CGFloat = 0, bch: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        guard let c = NSColor(self).usingColorSpace(.deviceRGB) else { return .white }
        r = c.redComponent; g = c.greenComponent; bch = c.blueComponent
        #else
        UIColor(self).getRed(&r, green: &g, blue: &bch, alpha: &a)
        #endif
        let luminance = 0.299 * r + 0.587 * g + 0.114 * bch
        return luminance > 0.55 ? .black : .white
    }
}

enum GridDensity: String, CaseIterable {
    case compact = "compact"
    case regular = "regular"
    case large   = "large"

    var cardWidth:  CGFloat { switch self { case .compact: 128; case .regular: 172; case .large: 220 } }
    var cardHeight: CGFloat { switch self { case .compact: 192; case .regular: 258; case .large: 330 } }
    var spacing:    CGFloat { switch self { case .compact: 14;  case .regular: 22;  case .large: 28  } }
    var icon:       String  { switch self { case .compact: "square.grid.3x3.fill"
                                           case .regular:  "square.grid.2x2.fill"
                                           case .large:    "square.fill" } }
}

enum Design {
    static let cardWidth:       CGFloat = 172
    static let cardHeight:      CGFloat = 258
    static let groupCardWidth:  CGFloat = 220
    // Matches cardWidth:cardHeight's exact 2:3 ratio (was 310, a noticeably wider 0.71 ratio than
    // real comic covers, which run close to 2:3 -- that mismatch alone forced significantly more
    // of every cover to be cropped away than the individual issue card needed).
    static let groupCardHeight: CGFloat = 330
    /// Same value as `Radius.card` -- kept as its own constant (not `Radius.card` inline) purely
    /// because ~25 call sites already spell it `Design.cardCorner`; renaming all of them for a
    /// token-location change with zero visual effect isn't worth the diff.
    static let cardCorner:      CGFloat = 10
    static let gridSpacing:     CGFloat = 22

    /// A shared spacing/corner-radius scale -- lets new code reach for `Design.Spacing.md` instead
    /// of guessing at another one-off magic number, without forcing a mechanical rewrite of every
    /// existing `.padding(_, 12)` call site (most of which are fine as plain literals already).
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
    }

    /// Named large-display styles for the handful of spots hand-rolling `.font(.system(size: N))`
    /// at similar-but-not-identical sizes (recap hero numbers, empty-state icons) -- one definition
    /// each instead of several slightly different ad hoc sizes.
    enum Typography {
        static let heroNumber    = Font.system(size: 64, weight: .black, design: .rounded)
        static let heroSeal      = Font.system(size: 40, weight: .regular)
        static let emptyStateIcon = Font.system(size: 52, weight: .regular)

        /// The small end of the scale -- row-metadata text (rating stars, item counts, trailing
        /// chevrons, small placeholder icons) that several card-style rows independently
        /// hand-rolled at the same handful of sizes. Named here so a card that needs "the size a
        /// star-rating glyph is" reads that intent instead of a bare magic number.
        static let microLabel     = Font.system(size: 10)
        static let microGlyph     = Font.system(size: 9)
        static let starGlyph      = Font.system(size: 7)
        static let rowIcon        = Font.system(size: 14)
        static let rowTitle       = Font.system(size: 13, weight: .semibold)
    }

    static var appBackground: Color { AppTheme.current.palette.appBackground }
    static var navBackground: Color { AppTheme.current.palette.navBackground }
    static var cardBg:        Color { AppTheme.current.palette.cardBg }
    static var surfaceBg:     Color { AppTheme.current.palette.surfaceBg }
    static var borderColor:   Color { AppTheme.current.palette.borderColor }

    static let secondaryLabel = Color.secondary

    static var brandBlue: Color {
        if let hex = UserDefaults.standard.string(forKey: "customAccentColorHex"), let c = Color(hex: hex) {
            return c
        }
        return AppTheme.current.palette.brandBlue
    }
    static var brandGold: Color { AppTheme.current.palette.brandGold }

    /// The hover spotlight's fallback tint for a cover whose accent color hasn't loaded yet (or
    /// never resolved to anything strongly saturated) -- a warm amber-white standing in for
    /// "display-case light" rather than falling back to a cold/neutral glow.
    static let warmSpotlightDefault = Color(red: 1.0, green: 0.92, blue: 0.78)

    static var textPrimary: Color { AppTheme.current.isLight ? Color(red: 0.13, green: 0.11, blue: 0.08) : .white }

    static var goldGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.980, green: 0.749, blue: 0.118),
                     Color(red: 0.855, green: 0.580, blue: 0.047)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    static let springSnappy   = Animation.spring(response: 0.3, dampingFraction: 0.75)
    static let springBouncy   = Animation.spring(response: 0.4, dampingFraction: 0.65)
    static let springGentle   = Animation.spring(response: 0.5, dampingFraction: 0.85)
    static let easeStandard   = Animation.easeInOut(duration: 0.2)
    static let easeFast       = Animation.easeOut(duration: 0.15)

    static func motion(_ animation: Animation, reduce: Bool) -> Animation {
        reduce ? .default : animation
    }

    /// The system Reduce Motion setting, read directly rather than via `@Environment` -- for the
    /// handful of `withAnimation` call sites that live in a `ViewModel`/non-View type (navigation
    /// state changes in `LibraryViewModel`), which has no SwiftUI environment to read from.
    /// View-level code should still prefer `@Environment(\.accessibilityReduceMotion)`; this is
    /// only for call sites that structurally can't.
    static var systemReduceMotionEnabled: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// Gate for the art-driven "atmosphere" surfaces (series/character headers, sidebar
    /// highlighting, background washes) that lean on a cover's own color -- returns nil (meaning
    /// "fall back to the neutral theme") whenever Increase Contrast or Differentiate Without
    /// Color is on, the same reduce-to-neutral shape `motion(_:reduce:)` uses for animation.
    /// Every call site that wants cover-derived color on anything bigger than a hover glow should
    /// route through this rather than using a raw cache color directly.
    static func atmosphericTint(_ color: Color?, increaseContrast: Bool, differentiateWithoutColor: Bool) -> Color? {
        guard !increaseContrast, !differentiateWithoutColor, let color else { return nil }
        return color.clampedForAtmosphere()
    }

    /// Same accessibility gate as `atmosphericTint`, but for the reader's near-black backdrop
    /// specifically -- a hint of the comic's own cover color behind the page rather than flat
    /// black, without touching the reader chrome's white icon/text contrast system at all.
    static func deepBackdropTint(_ color: Color?, increaseContrast: Bool, differentiateWithoutColor: Bool) -> Color {
        guard !increaseContrast, !differentiateWithoutColor, let color else { return .black }
        return color.clampedForDeepBackdrop()
    }

    /// Same accessibility gate again, for the `GroupCard` gradient scrim -- falls back to plain
    /// black (the scrim's original look) rather than nil, since the scrim always needs *a* color.
    static func scrimTint(_ color: Color?, increaseContrast: Bool, differentiateWithoutColor: Bool) -> Color {
        guard !increaseContrast, !differentiateWithoutColor, let color else { return .black }
        return color.clampedForScrim()
    }

    static func publisherColor(_ pub: String) -> Color {
        switch pub.lowercased() {
        case "dc":     return Color(red: 0.157, green: 0.420, blue: 0.886)
        case "marvel": return Color(red: 0.839, green: 0.157, blue: 0.157)
        case "manga":  return Color(red: 0.600, green: 0.157, blue: 0.729)
        case "indie":  return Color(red: 0.133, green: 0.549, blue: 0.133)
        default:       return Color(red: 0.350, green: 0.350, blue: 0.420)
        }
    }
}

enum ProgressFormat: String, CaseIterable {
    case fraction = "fraction"
    case percent  = "percent"
    case status   = "status"
    case hidden   = "hidden"

    var label: String {
        switch self {
        case .fraction: return "12/45 Issues"
        case .percent:  return "26%"
        case .status:   return "Completed / In Progress"
        case .hidden:   return "Hidden"
        }
    }

    func text(finished: Int, started: Int, total: Int) -> String? {
        switch self {
        case .hidden:
            return nil
        case .fraction:
            return "\(finished)/\(total) finished"
        case .percent:
            let pct = total > 0 ? Int(Double(finished) / Double(total) * 100) : 0
            return "\(pct)% complete"
        case .status:
            if total > 0 && finished == total { return "Completed" }
            if started > 0 || finished > 0    { return "In Progress" }
            return "Unread"
        }
    }
}
