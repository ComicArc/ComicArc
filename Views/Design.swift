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

extension View {
    /// `accentColor`/`isHovered` are opt-in -- every call site that doesn't pass them gets the
    /// exact same flat black shadow as before. Only a hovered card with a known accent color
    /// (currently just `ComicCard`) gets a glow tinted from that comic's own cover, never the
    /// resting/unhovered state, so grids never look tinted while just sitting there. The thin edge
    /// ring rides along with the same tint so hover reads as "this cover's color", not just a
    /// generic glow behind it.
    /// `restingTint` is the "maximal art-driven" resting-state counterpart to `accentColor`/
    /// `isHovered` above -- a softer, always-on glow (not gated on hover) for cards where the
    /// group itself (a whole series/character, not a single issue sitting in a scrolling grid)
    /// is meant to carry a bit of its own color at rest. `ComicCard`'s existing hover-only
    /// behavior is unchanged when `restingTint` is nil (the default), preserving the deliberate
    /// "grids never look tinted while just sitting there" rule for individual issue covers.
    /// `fallbackTint` is the spotlight's color when no cover-derived `accentColor` has resolved
    /// yet -- defaults to the neutral warm glow, but callers that know which publisher a comic
    /// belongs to should pass `Design.publisherColor(comic.publisher)` instead, so the *default*
    /// glow varies by section (Marvel red, DC blue, manga purple...) rather than every comic in
    /// the library defaulting to the exact same amber. Once the real cover accent loads, it still
    /// wins -- this only changes what shows while waiting for that, and what a comic whose cover
    /// never resolves to a strong color falls back to.
    ///
    /// `theme` is how a card's hover response becomes theme-aware WITHOUT this function (or its
    /// caller) ever branching on which theme it is -- `theme.interaction.hoverGlowMultiplier`/
    /// `hoverShadowRadius`/`accentColor` scale the exact same spotlight/shadow/stroke this
    /// function has always drawn, just more or less dramatically depending on the active
    /// `ComicTheme` (read from `\.comicTheme` by the caller, defaulting to `.library`'s calm
    /// baseline everywhere that doesn't override it).
    func comicCardStyle(accentColor: Color? = nil, isHovered: Bool = false, restingTint: Color? = nil,
                         fallbackTint: Color = Design.warmSpotlightDefault, theme: ComicTheme = .library) -> some View {
        let hoverTint = isHovered ? (accentColor ?? theme.accentColor) : nil
        let glow = theme.interaction.hoverGlowMultiplier
        let shadowColor  = hoverTint?.opacity(min(0.5 * glow, 0.85)) ?? restingTint?.opacity(0.35) ?? .black.opacity(0.45)
        let shadowRadius: CGFloat = hoverTint != nil ? theme.interaction.hoverShadowRadius : (restingTint != nil ? 10 : 8)
        let shadowY:      CGFloat = hoverTint != nil ? 8  : (restingTint != nil ? 5  : 4)
        let strokeColor  = hoverTint?.opacity(min(0.6 * glow, 0.9)) ?? restingTint?.opacity(0.4) ?? .clear
        // The "display-case spotlight": a soft, wide light pool that spills past the cover's own
        // edges on hover -- a plain tinted shadow reads as UI chrome, a wash this much wider than
        // the card itself (and this soft) reads as a light source. Faded fully out (not just
        // absent) at rest so grids never look tinted while just sitting there, matching the same
        // "hover-only" rule the shadow/ring above already follow. Its color is still the cover's
        // own accent when known -- `theme` only ever scales intensity/radius/border, never
        // overrides a real cover color, so the spotlight stays "this comic's own light," just
        // brighter or dimmer depending on the room it's sitting in.
        let spotlightTint = accentColor ?? fallbackTint
        return self
            .clipShape(Rectangle())
            .background(
                GeometryReader { geo in
                    // Only ever built while actually hovered -- at rest this whole block is
                    // skipped, not just hidden at zero opacity, so a grid of thousands of cards
                    // costs nothing extra beyond the one card the pointer is actually over.
                    if isHovered {
                        // A small FIXED margin (not a multiplier of card size) so the bleed past
                        // the card's own edges stays the same regardless of how big the card is.
                        // Only one card is ever hovered at once, so the safety threshold is the
                        // FULL gap to a neighbor, not half of it (there's no second halo meeting
                        // this one halfway) -- 12pt stays under even the grid's tightest
                        // (compact-density, 14pt) spacing with a couple points to spare, while
                        // actually being big enough to read as a halo instead of a sliver.
                        let haloMargin: CGFloat = 12
                        let w = geo.size.width, h = geo.size.height
                        // Circular glows (soft/searchlight/sunburst) stay true circles, sized off
                        // the SHORTER card dimension -- safe on both axes, at the cost of not
                        // reaching the long axis's own edges on a portrait card.
                        let circleSide = min(w, h) + haloMargin * 2
                        // Line-based effects (web/speed lines/radar rings) instead match the
                        // card's own aspect ratio -- a rectangle, not a square, so a tall card gets
                        // a tall pattern (longer spokes/rings on its long axis) instead of being
                        // squashed into a square sized off the card's longer dimension, which is
                        // what made the web look short and wide on portrait covers before.
                        let boxW = w + haloMargin * 2, boxH = h + haloMargin * 2
                        switch theme.interaction.cardSpotlight {
                        case .soft:
                            RadialGradient(
                                colors: [spotlightTint.opacity(min(0.55 * glow, 0.85)), spotlightTint.opacity(0)],
                                center: .center, startRadius: 0, endRadius: circleSide / 2
                            )
                            .frame(width: circleSide, height: circleSide)
                            .position(x: w / 2, y: h / 2)
                            .blendMode(.screen)
                            .allowsHitTesting(false)
                        case .searchlight(let searchTint):
                            // A tight, defined circle -- reads as a circular light being cast on
                            // the comic, like a signal pointed at it. The bright core holds most
                            // of the way out and then cuts off fast, rather than a long, soft,
                            // hazy falloff -- a defined spotlight disc, not a diffuse cloud.
                            Circle()
                                .fill(RadialGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: searchTint.opacity(0.9), location: 0),
                                        .init(color: searchTint.opacity(0.9), location: 0.6),
                                        .init(color: searchTint.opacity(0.25), location: 0.85),
                                        .init(color: searchTint.opacity(0), location: 1.0)
                                    ]),
                                    center: .center, startRadius: 0, endRadius: circleSide / 2
                                ))
                                .frame(width: circleSide, height: circleSide)
                                .position(x: w / 2, y: h / 2)
                                .blendMode(.screen)
                                .allowsHitTesting(false)
                        case .webStrands(let webTint):
                            // A radial web -- spokes from a center point plus concentric connecting
                            // rings, parametrized as an ellipse (independent x/y radii) rather than
                            // a true circle so the pattern stretches to match the card's own
                            // proportions -- longer spokes on a tall card's long axis, not a small
                            // circle squashed inside a square. `Canvas` clips its own drawing to
                            // its frame, so the web reads as continuing off past its own edges
                            // rather than being cut off mid-line.
                            Canvas { context, size in
                                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                                let rx = size.width / 2, ry = size.height / 2
                                let spokeCount = 10
                                let ringCount = 4
                                for i in 0..<spokeCount {
                                    let angle = Double(i) / Double(spokeCount) * 2 * .pi
                                    let end = CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle))
                                    var path = Path()
                                    path.move(to: center)
                                    path.addLine(to: end)
                                    context.stroke(path, with: .color(webTint.opacity(0.7)), lineWidth: 1.3)
                                }
                                for r in 1...ringCount {
                                    let fraction = CGFloat(r) / CGFloat(ringCount)
                                    var path = Path()
                                    for i in 0...spokeCount {
                                        let angle = Double(i % spokeCount) / Double(spokeCount) * 2 * .pi
                                        let pt = CGPoint(x: center.x + rx * fraction * cos(angle), y: center.y + ry * fraction * sin(angle))
                                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                                    }
                                    context.stroke(path, with: .color(webTint.opacity(0.55)), lineWidth: 1.2)
                                }
                            }
                            .frame(width: boxW, height: boxH)
                            .position(x: w / 2, y: h / 2)
                            .blendMode(.screen)
                            .allowsHitTesting(false)
                        case .sunburst(let sunTint):
                            // Just a warm radiant glow -- no ray lines.
                            Circle()
                                .fill(RadialGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: sunTint.opacity(0.85), location: 0),
                                        .init(color: sunTint.opacity(0.85), location: 0.45),
                                        .init(color: sunTint.opacity(0.2), location: 0.8),
                                        .init(color: sunTint.opacity(0), location: 1.0)
                                    ]),
                                    center: .center, startRadius: 0, endRadius: circleSide / 2
                                ))
                                .frame(width: circleSide, height: circleSide)
                                .position(x: w / 2, y: h / 2)
                                .blendMode(.screen)
                                .allowsHitTesting(false)
                        case .speedLines(let speedTint):
                            // A handful of horizontal streaks entering from the left, tapering in
                            // length -- reads as a blur of motion rushing past.
                            Canvas { context, size in
                                let lineCount = 6
                                for i in 0..<lineCount {
                                    let y = size.height * (0.12 + 0.76 * CGFloat(i) / CGFloat(lineCount - 1))
                                    let length = size.width * (0.4 + 0.3 * CGFloat(i % 3) / 2)
                                    var path = Path()
                                    path.move(to: CGPoint(x: 0, y: y))
                                    path.addLine(to: CGPoint(x: length, y: y))
                                    context.stroke(path, with: .color(speedTint.opacity(0.6)), lineWidth: 2)
                                }
                            }
                            .frame(width: boxW, height: boxH)
                            .position(x: w / 2, y: h / 2)
                            .blendMode(.screen)
                            .allowsHitTesting(false)
                        case .radarPing(let pingTint):
                            // Concentric ring outlines from the center, parametrized as ellipses
                            // (independent x/y radii) so the rings match the card's own
                            // proportions -- a static "ping," not an expanding animation.
                            Canvas { context, size in
                                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                                let rx = size.width / 2 * 0.96, ry = size.height / 2 * 0.96
                                let ringCount = 4
                                for r in 1...ringCount {
                                    let fraction = CGFloat(r) / CGFloat(ringCount)
                                    let radiusX = rx * fraction, radiusY = ry * fraction
                                    let rect = CGRect(x: center.x - radiusX, y: center.y - radiusY, width: radiusX * 2, height: radiusY * 2)
                                    context.stroke(Path(ellipseIn: rect), with: .color(pingTint.opacity(0.55)), lineWidth: 1.2)
                                }
                            }
                            .frame(width: boxW, height: boxH)
                            .position(x: w / 2, y: h / 2)
                            .blendMode(.screen)
                            .allowsHitTesting(false)
                        }
                    }
                }
            )
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
            .overlay(Rectangle().stroke(strokeColor, lineWidth: 1.5))
    }

    func goldButton() -> some View {
        self
            .buttonStyle(GoldCapsuleStyle())
    }

    /// The hover-scale micro-interaction every card type in the library uses (`ComicCard`,
    /// `GroupCard`, and the shelf cards) -- previously the identical `@State isHovered` +
    /// `.scaleEffect` + `.animation` + `.onHover` triad copy-pasted at each call site. Owns its
    /// own hover state by default, so a plain call site just needs this one modifier, nothing
    /// else. Pass `isHovered:` when the caller also needs the boolean itself (e.g. `ComicCard`
    /// tinting its cover's glow from the same hover state) -- the modifier then drives that
    /// binding instead of a private one, so there's still only one hover-tracking + animation
    /// implementation, not two.
    func hoverLift(scale: CGFloat = 1.03, duration: Double = 0.15, isHovered: Binding<Bool>? = nil) -> some View {
        modifier(HoverLiftModifier(scale: scale, duration: duration, externalIsHovered: isHovered))
    }

    /// A tiny, deterministic tilt for horizontal "shelf" rows (`ShelfCard`, `OnThisDayCard`,
    /// `RecommendedCard`) -- picked from the comic's own id, not `.random()`, so it's stable
    /// across re-renders instead of jittering every time SwiftUI recomputes the view. Evokes
    /// items casually leaned on a shelf rather than machine-aligned. Deliberately never applied
    /// to the main browsing grid (`ComicCard`/`GroupCard`) -- that still needs to scan cleanly as
    /// an orderly collection, not a messy pile; tilt is reserved for these curated, glanceable
    /// rows. Straightens to 0° on hover (rides the same hover-driven animation `hoverLift`'s
    /// `isHovered` already provides), like picking the one you're actually looking at off the
    /// shelf.
    func shelfTilt(seed: Int64, isHovered: Bool) -> some View {
        let steps = [-1.4, -0.7, 0.7, 1.4]
        let angle = steps[Int(abs(seed) % Int64(steps.count))]
        return rotationEffect(.degrees(isHovered ? 0 : angle))
    }
}

/// A faint halftone/ben-day dot texture -- the one visual cue that reads as "printed comic," not
/// just "warm app." Kept extremely subtle (low opacity, static, no per-pixel randomness) so it
/// stays a whisper of paper/ink underneath hero moments rather than competing with cover art or
/// text. `Canvas`-drawn rather than a tiled image asset so it has no bundle cost and naturally
/// re-tints per theme.
struct HalftoneTexture: View {
    var tint: Color = .white
    var dotSpacing: CGFloat = 13
    var dotRadius: CGFloat = 1.1
    var opacity: Double = 0.05

    var body: some View {
        Canvas { context, size in
            let fill = GraphicsContext.Shading.color(tint.opacity(opacity))
            var row = 0
            var y = dotRadius
            while y < size.height + dotSpacing {
                let rowOffset = row.isMultiple(of: 2) ? 0 : dotSpacing / 2
                var x = dotRadius + rowOffset
                while x < size.width + dotSpacing {
                    let rect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                    context.fill(Path(ellipseIn: rect), with: fill)
                    x += dotSpacing
                }
                y += dotSpacing
                row += 1
            }
        }
        .allowsHitTesting(false)
    }
}

/// The app's mark: a classic comic "impact burst" (alternating long/short spikes radiating from
/// center, the shape behind every POW/BAM) -- unambiguously "comic," not just "warm."
/// `Shape`-drawn (not an asset) so it scales cleanly at any size and re-tints with
/// `Design.goldGradient` like the mark always has.
struct ComicBurstShape: Shape {
    var points: Int = 10
    var innerRatio: CGFloat = 0.5

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * innerRatio
        let totalPoints = points * 2
        var path = Path()
        for i in 0..<totalPoints {
            let angle = CGFloat(i) * .pi / CGFloat(points) - .pi / 2
            let radius = i.isMultiple(of: 2) ? outerRadius : innerRadius
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Shared decorative shapes
//
// A minimal set of generic, reusable shapes the theme and empty-state systems below draw on --
// not tied to any specific character or publisher's owned imagery. There is no standalone
// "Easter egg" layer in this app; every decorative element here exists because a real system
// (a `ComicTheme`'s ambient effects, or an `EmptyStateView` illustration) actually uses
// it, not as a hidden detail placed for its own sake.

/// A classic comic speech-bubble silhouette (rounded rect + a small triangular tail) -- used as
/// an empty-state illustration base, standing in for a plain SF Symbol where a search/question
/// moment calls for a little more personality.
struct SpeechBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let bubbleRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.78)
        var path = Path(roundedRect: bubbleRect, cornerRadius: bubbleRect.height * 0.28)
        path.move(to: CGPoint(x: bubbleRect.minX + bubbleRect.width * 0.28, y: bubbleRect.maxY))
        path.addLine(to: CGPoint(x: bubbleRect.minX + bubbleRect.width * 0.2, y: rect.maxY))
        path.addLine(to: CGPoint(x: bubbleRect.minX + bubbleRect.width * 0.42, y: bubbleRect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Theme engine
//
// A theme is exactly two things: an **environment** (lighting -- a barely-there tint over the
// app's one global background, plus at most one small ambient detail) and an **interaction**
// (how a card's existing hover spotlight/lift/shadow responds). Nothing else changes -- layout,
// typography, and the base background stay identical everywhere. No view anywhere branches on a
// theme's identity (no `if theme.id == "gothic"` in a View body); every view that participates
// only ever reads `ComicTheme.Environment`/`Interaction`'s generic numeric/color fields, via the
// `\.comicTheme` environment key below. That's what makes adding a new theme a pure-data change:
// one new `ComicTheme` in the registry, zero UI code touched.
//
// The comic cover is always the brightest, sharpest thing on screen. A themed screen shows the
// base tint plus the shared vignette plus AT MOST ONE extra accent (its ambient detail if it has
// one, else its spotlight wash) -- never both stacked together, and nothing animates continuously.
// The room's lighting changes when you walk in; it doesn't keep moving once you're standing there.
//
// `AmbientEffect` is the small, closed, REUSABLE vocabulary of generic decorative primitives
// (mist, rain, a skyline sliver, soft clouds, a light streak, stars, a tech grid, film grain) --
// none of it reproduces any owned logo, emblem, or character likeness. Detection has two tiers:
// first, a name-keyword match against the character/series' own name (the user's own library
// metadata -- matching a string to pick a decorative preset is categorization, the same as a
// bookstore's shelving software sorting "Harry Potter" onto the fantasy shelf, not a reproduction
// of anyone's artwork); second, a fallback derived from that collection's own cover-art color when
// no keyword matches, so literally every collection gets a distinct identity.

enum AmbientEffect {
    case mist
    case rain
    case skyline
    case clouds
    case streak
    case stars
    case grid
    case grain
}

enum SpotlightShape {
    /// A soft radial pool, centered -- the default "display-case light" every card already has.
    case bloom
    /// A directional wedge, like a searchlight or a raking side-light -- reads as a light
    /// *source*, not just a glow.
    case beam
    /// A very wide, very soft wash -- less a spotlight than the whole scene being lit warmly.
    case glow
}

struct SpotlightStyle {
    /// Base multiplier on top of the existing hover-spotlight opacity every card already draws --
    /// 1.0 matches the neutral default, >1 reads as a brighter/more dramatic light source. Tinted
    /// by the owning theme's own `accentColor`, never a separate color of its own.
    let intensity: Double
    let shape: SpotlightShape
}

/// How a card's own hover spotlight actually renders -- distinct from `SpotlightStyle` above,
/// which only shapes the ambient background wash. Test case: `.gothic`'s `.searchlight`, a tight,
/// defined circle rather than the default wide soft pool -- evokes a search/signal light without
/// reproducing any owned emblem (no bat shape drawn, just the light itself).
enum CardHoverSpotlight {
    /// Today's default -- the wide, soft radial pool every card already has, tinted from the
    /// comic's own cover accent.
    case soft
    /// A tight circular beam with a defined edge, in the theme's own fixed tint (not the cover's
    /// accent) -- narrows onto the cover on hover rather than spilling softly past its edges.
    case searchlight(tint: Color)
    /// A radial web -- spokes from a center point plus concentric connecting rings, like an actual
    /// spiderweb silhouette -- sized to bleed past the card's own edges into the space around it.
    case webStrands(tint: Color)
    /// A warm radiant core, no rays -- like sunlight or a power glow depending on tint.
    case sunburst(tint: Color)
    /// A handful of horizontal motion-blur streaks rushing in from one side -- something moving
    /// too fast to see clearly. No lightning-bolt icon drawn.
    case speedLines(tint: Color)
    /// Concentric ring outlines expanding from the center, like a radar/sonar ping -- heightened
    /// senses, not a literal radar dish.
    case radarPing(tint: Color)
}

struct ComicTheme: Identifiable {
    let id: String
    let keywords: [String]

    /// The one color a theme actually owns -- used for the spotlight tint, the card hover
    /// border/rim, and (very faintly) the environment tint below. Everything themed traces back
    /// to this single value, not a separate palette per surface.
    let accentColor: Color

    /// The "lighting" half of a theme -- literally just two fields, per the "a theme is exactly
    /// two things" rule above.
    struct Environment {
        /// Two close-hued, low-saturation gradient stops, blended at low opacity over the app's
        /// one global `Design.appBackground` -- reads as color-graded lighting, never a distinct
        /// scene or wallpaper. Empty means no tint at all, i.e. the plain base background --
        /// what `.library`/`.neutral` use.
        var backgroundTint: [Color] = []
        /// At most one, always small and confined to a corner of the screen. When present, this
        /// is the theme's one extra accent -- `ThemeBackdrop` shows this OR the spotlight wash
        /// below, never both, so a themed screen never stacks more than tint + vignette + one
        /// accent.
        var ambientEffect: AmbientEffect? = nil
    }

    /// The "hover" half of a theme -- how much MORE dramatic this theme makes a card's own
    /// existing hover response. Every `ComicCard`/`GroupCard` already has a spotlight/lift/shadow
    /// on hover; these fields scale that existing behavior rather than replacing it with
    /// theme-specific logic. This is where a theme's personality actually shows -- the
    /// environment only ever sets the mood quietly.
    struct Interaction {
        var spotlight: SpotlightStyle
        var cardSpotlight: CardHoverSpotlight = .soft
        var hoverGlowMultiplier: Double = 1.0
        var hoverLiftScale: CGFloat = 1.03
        var hoverShadowRadius: CGFloat = 16
        /// 120-300ms -- how quickly the lift/glow settle. The one place pacing itself varies by
        /// theme, since the environment no longer changes on hover at all.
        var hoverAnimationDuration: Double = 0.15
        /// How long the environment crossfades when navigating into/out of this theme.
        var transitionDuration: Double = 0.4
    }

    let environment: Environment
    let interaction: Interaction

    /// Builds a registry entry from flat arguments -- keeps the registry below a plain,
    /// scannable list of values instead of nested struct literals repeated at every entry.
    private static func make(id: String, keywords: [String], accentColor: Color,
                              tint: [Color] = [], ambient: AmbientEffect? = nil,
                              spotlightIntensity: Double = 1.0, spotlightShape: SpotlightShape = .bloom,
                              cardSpotlight: CardHoverSpotlight = .soft,
                              glow: Double = 1.0, lift: CGFloat = 1.03, shadow: CGFloat = 16,
                              hoverDuration: Double = 0.15, transition: Double = 0.4) -> ComicTheme {
        ComicTheme(id: id, keywords: keywords, accentColor: accentColor,
                   environment: Environment(backgroundTint: tint, ambientEffect: ambient),
                   interaction: Interaction(spotlight: SpotlightStyle(intensity: spotlightIntensity, shape: spotlightShape),
                                             cardSpotlight: cardSpotlight,
                                             hoverGlowMultiplier: glow, hoverLiftScale: lift, hoverShadowRadius: shadow,
                                             hoverAnimationDuration: hoverDuration, transitionDuration: transition))
    }

    // Hover glow is capped at 1.4x across the whole registry (previously peaked at 1.5x) and no
    // theme stacks tint + vignette + spotlight + ambient detail simultaneously anymore -- see
    // `ThemeBackdrop` below for how environment now picks at most one accent.
    static let registry: [ComicTheme] = [
        .make(id: "gothic", keywords: ["batman", "gotham", "dark knight", "nightwing", "robin", "outsiders"],
              accentColor: Color(red: 0.55, green: 0.65, blue: 0.85),
              tint: [Color(red: 0.05, green: 0.07, blue: 0.10), Color(red: 0.13, green: 0.17, blue: 0.24)],
              ambient: .mist, spotlightIntensity: 1.2, spotlightShape: .beam,
              cardSpotlight: .searchlight(tint: Color(red: 0.80, green: 0.88, blue: 1.0)),
              glow: 1.3, lift: 1.03, shadow: 22, hoverDuration: 0.30, transition: 0.5),
        .make(id: "webbed", keywords: ["spider-man", "spiderman", "spider man", "venom", "miles morales"],
              accentColor: Color(red: 0.85, green: 0.25, blue: 0.2),
              tint: [Color(red: 0.11, green: 0.05, blue: 0.04), Color(red: 0.25, green: 0.09, blue: 0.07)],
              ambient: .skyline, spotlightIntensity: 1.3, spotlightShape: .bloom,
              cardSpotlight: .webStrands(tint: Color(red: 0.95, green: 0.96, blue: 1.0)),
              glow: 1.4, lift: 1.05, shadow: 18, hoverDuration: 0.15, transition: 0.3),
        .make(id: "celestial", keywords: ["superman", "supergirl", "superboy"],
              accentColor: Color(red: 1.0, green: 0.93, blue: 0.75),
              tint: [Color(red: 0.11, green: 0.09, blue: 0.05), Color(red: 0.24, green: 0.19, blue: 0.11)],
              ambient: .clouds, spotlightIntensity: 1.3, spotlightShape: .glow,
              cardSpotlight: .sunburst(tint: Color(red: 0.35, green: 0.9, blue: 0.5)),
              glow: 1.4, lift: 1.03, shadow: 16, hoverDuration: 0.22, transition: 0.4),
        .make(id: "wonderwoman", keywords: ["wonder woman", "amazons", "themyscira"],
              accentColor: Color(red: 0.9, green: 0.75, blue: 0.4),
              tint: [Color(red: 0.13, green: 0.08, blue: 0.05), Color(red: 0.26, green: 0.17, blue: 0.09)],
              spotlightIntensity: 1.2, spotlightShape: .glow,
              cardSpotlight: .searchlight(tint: Color(red: 1.0, green: 0.85, blue: 0.45)),
              glow: 1.35, lift: 1.04, shadow: 16, hoverDuration: 0.22, transition: 0.4),
        .make(id: "speedster", keywords: ["flash", "quicksilver", "impulse", "kid flash"],
              accentColor: Color(red: 1.0, green: 0.8, blue: 0.3),
              tint: [Color(red: 0.12, green: 0.03, blue: 0.03), Color(red: 0.26, green: 0.06, blue: 0.04)],
              ambient: .streak, spotlightIntensity: 1.4, spotlightShape: .beam,
              cardSpotlight: .speedLines(tint: Color(red: 1.0, green: 0.85, blue: 0.35)),
              glow: 1.4, lift: 1.06, shadow: 14, hoverDuration: 0.12, transition: 0.25),
        .make(id: "lantern", keywords: ["green lantern", "hal jordan", "john stewart", "sinestro"],
              accentColor: Color(red: 0.25, green: 0.85, blue: 0.45),
              tint: [Color(red: 0.03, green: 0.09, blue: 0.05), Color(red: 0.05, green: 0.20, blue: 0.10)],
              ambient: .stars, spotlightIntensity: 1.2, spotlightShape: .bloom,
              cardSpotlight: .searchlight(tint: Color(red: 0.35, green: 0.95, blue: 0.55)),
              glow: 1.4, lift: 1.04, shadow: 18, hoverDuration: 0.22, transition: 0.4),
        .make(id: "xmen", keywords: ["x-men", "xmen", "wolverine", "cyclops", "professor x", "magneto"],
              accentColor: Color(red: 0.4, green: 0.55, blue: 0.75),
              tint: [Color(red: 0.06, green: 0.08, blue: 0.12), Color(red: 0.12, green: 0.16, blue: 0.22)],
              ambient: .grid, spotlightIntensity: 1.1, spotlightShape: .beam,
              cardSpotlight: .searchlight(tint: Color(red: 0.55, green: 0.7, blue: 0.95)),
              glow: 1.25, lift: 1.03, shadow: 16, hoverDuration: 0.20, transition: 0.4),
        .make(id: "daredevil", keywords: ["daredevil", "matt murdock", "hell's kitchen"],
              accentColor: Color(red: 0.7, green: 0.12, blue: 0.14),
              tint: [Color(red: 0.06, green: 0.02, blue: 0.02), Color(red: 0.20, green: 0.03, blue: 0.03)],
              ambient: .rain, spotlightIntensity: 1.0, spotlightShape: .beam,
              cardSpotlight: .radarPing(tint: Color(red: 0.9, green: 0.2, blue: 0.22)),
              glow: 1.3, lift: 1.02, shadow: 24, hoverDuration: 0.28, transition: 0.5),
        .make(id: "fantasticfour", keywords: ["fantastic four", "mr fantastic", "invisible woman", "human torch"],
              accentColor: Color(red: 0.35, green: 0.55, blue: 0.85),
              tint: [Color(red: 0.04, green: 0.08, blue: 0.13), Color(red: 0.08, green: 0.16, blue: 0.26)],
              ambient: .skyline, spotlightIntensity: 1.2, spotlightShape: .glow,
              cardSpotlight: .sunburst(tint: Color(red: 0.45, green: 0.65, blue: 0.95)),
              glow: 1.3, lift: 1.04, shadow: 16, hoverDuration: 0.18, transition: 0.35),
        .make(id: "hulk", keywords: ["hulk", "bruce banner", "gamma"],
              accentColor: Color(red: 0.35, green: 0.65, blue: 0.35),
              tint: [Color(red: 0.04, green: 0.08, blue: 0.04), Color(red: 0.07, green: 0.18, blue: 0.07)],
              spotlightIntensity: 0.9, spotlightShape: .beam,
              cardSpotlight: .searchlight(tint: Color(red: 0.45, green: 0.75, blue: 0.35)),
              glow: 1.2, lift: 1.02, shadow: 26, hoverDuration: 0.30, transition: 0.5),
        .make(id: "thor", keywords: ["thor", "asgard", "odin", "mjolnir"],
              accentColor: Color(red: 0.75, green: 0.82, blue: 0.95),
              tint: [Color(red: 0.07, green: 0.08, blue: 0.12), Color(red: 0.15, green: 0.17, blue: 0.24)],
              ambient: .streak, spotlightIntensity: 1.3, spotlightShape: .beam,
              cardSpotlight: .searchlight(tint: Color(red: 0.8, green: 0.85, blue: 1.0)),
              glow: 1.4, lift: 1.04, shadow: 18, hoverDuration: 0.18, transition: 0.4),
        .make(id: "strange", keywords: ["doctor strange", "sorcerer supreme", "stephen strange"],
              accentColor: Color(red: 0.65, green: 0.4, blue: 0.85),
              tint: [Color(red: 0.06, green: 0.04, blue: 0.12), Color(red: 0.16, green: 0.09, blue: 0.28)],
              ambient: .stars, spotlightIntensity: 1.2, spotlightShape: .glow,
              cardSpotlight: .radarPing(tint: Color(red: 0.75, green: 0.45, blue: 0.95)),
              glow: 1.4, lift: 1.04, shadow: 20, hoverDuration: 0.24, transition: 0.45),
        .make(id: "cosmic", keywords: ["guardians", "cosmic", "nova", "silver surfer"],
              accentColor: Color(red: 0.45, green: 0.5, blue: 0.95),
              tint: [Color(red: 0.03, green: 0.03, blue: 0.10), Color(red: 0.08, green: 0.08, blue: 0.24)],
              ambient: .stars, spotlightIntensity: 1.15, spotlightShape: .bloom,
              cardSpotlight: .sunburst(tint: Color(red: 0.55, green: 0.55, blue: 0.98)),
              glow: 1.3, lift: 1.04, shadow: 20, hoverDuration: 0.24, transition: 0.5),
        .make(id: "horror", keywords: ["swamp thing", "hellblazer", "constantine", "sandman", "horror"],
              accentColor: Color(red: 0.5, green: 0.12, blue: 0.14),
              tint: [Color(red: 0.015, green: 0.01, blue: 0.01), Color(red: 0.14, green: 0.025, blue: 0.03)],
              ambient: .mist, spotlightIntensity: 0.8, spotlightShape: .beam,
              glow: 1.15, lift: 1.02, shadow: 26, hoverDuration: 0.28, transition: 0.6),
        .make(id: "noir", keywords: ["noir"],
              accentColor: Color(red: 0.75, green: 0.75, blue: 0.75),
              tint: [Color(red: 0.025, green: 0.025, blue: 0.025), Color(red: 0.15, green: 0.15, blue: 0.15)],
              ambient: .grain, spotlightIntensity: 1.1, spotlightShape: .beam,
              glow: 1.2, lift: 1.02, shadow: 22, hoverDuration: 0.24, transition: 0.5),
        .make(id: "scifi", keywords: ["sci-fi", "science fiction", "cyborg", "robocop", "transformers", "iron man"],
              accentColor: Color(red: 0.3, green: 0.85, blue: 0.9),
              tint: [Color(red: 0.02, green: 0.08, blue: 0.09), Color(red: 0.04, green: 0.19, blue: 0.21)],
              ambient: .grid, spotlightIntensity: 1.2, spotlightShape: .beam,
              glow: 1.3, lift: 1.04, shadow: 16, hoverDuration: 0.16, transition: 0.3),
        .make(id: "fantasy", keywords: ["fantasy", "dungeons", "sword and sorcery"],
              accentColor: Color(red: 0.7, green: 0.75, blue: 0.4),
              tint: [Color(red: 0.06, green: 0.08, blue: 0.03), Color(red: 0.14, green: 0.17, blue: 0.07)],
              ambient: .stars, spotlightIntensity: 1.15, spotlightShape: .glow,
              glow: 1.3, lift: 1.04, shadow: 18, hoverDuration: 0.22, transition: 0.4),
    ]

    /// The default global theme: elegant, premium, neutral -- deliberately the calmest entry in
    /// the registry (no environment tint, standard hover) so switching INTO a named series theme
    /// is the moment that actually reads as a mood change. Used by `libraryAmbientBackground()`.
    static let library = ComicTheme.make(id: "library", keywords: [], accentColor: Design.warmSpotlightDefault,
                                          spotlightIntensity: 1.0, spotlightShape: .bloom,
                                          glow: 1.0, lift: 1.03, shadow: 16, hoverDuration: 0.15, transition: 0.5)

    /// The plain fallback for non-series, non-library screens (Diary, Runs, Stats, etc.) -- same
    /// calm baseline as `.library`.
    static let neutral = ComicTheme.make(id: "neutral", keywords: [], accentColor: Design.warmSpotlightDefault,
                                          spotlightIntensity: 1.0, spotlightShape: .bloom,
                                          glow: 1.0, lift: 1.03, shadow: 16, hoverDuration: 0.15, transition: 0.5)

    static func fromName(_ name: String?) -> ComicTheme? {
        guard let name else { return nil }
        let n = name.lowercased()
        return registry.first { $0.keywords.contains { n.contains($0) } }
    }

    /// Color-derived fallback for anything the name detector didn't recognize -- picked by hue,
    /// so literally every collection gets *some* distinct mood, not just the pre-listed handful.
    static func fromColor(_ color: Color?) -> ComicTheme {
        guard let color else { return .neutral }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        guard let c = NSColor(color).usingColorSpace(.deviceRGB) else { return .neutral }
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #endif
        guard s > 0.16, b > 0.1 else { return .neutral }
        let byId: (String) -> ComicTheme = { id in registry.first { $0.id == id }! }
        switch Double(h) * 360 {
        case 0..<25, 335...360: return byId("horror")
        case 25..<70:           return byId("celestial")
        case 70..<170:          return byId("lantern")
        case 170..<255:         return byId("cosmic")
        case 255..<335:         return byId("strange")
        default:                return .neutral
        }
    }

    /// Name match wins; the color-derived fallback only kicks in when nothing in the name
    /// matches, so a real Batman collection always gets `.gothic` regardless of that particular
    /// cover's own color, while everything else still gets *some* distinct identity.
    static func detect(name: String?, color: Color?) -> ComicTheme {
        fromName(name) ?? fromColor(color)
    }
}

private struct ComicThemeKey: EnvironmentKey {
    static let defaultValue = ComicTheme.library
}

extension EnvironmentValues {
    /// The active theme for whatever screen a card is rendered in -- `ComicCard`/`GroupCard` read
    /// this to scale their own existing hover spotlight/lift/shadow, without knowing anything
    /// about which theme it is. Defaults to `.library`, so the neutral main library (which never
    /// sets an override) gets the calm baseline for free.
    var comicTheme: ComicTheme {
        get { self[ComicThemeKey.self] }
        set { self[ComicThemeKey.self] = newValue }
    }
}

/// The environment half of a theme -- always `Design.appBackground` first, with at most a faint
/// gradient wash blended on top plus ONE small, corner-confined accent (the theme's ambient
/// detail if it has one, else its spotlight wash -- never both). Never a distinct scene, never
/// full-screen, and nothing here animates continuously: it fades in once on appear and crossfades
/// once when the detected theme changes, paced by that theme's own `transitionDuration`, then sits
/// still -- the room's lighting doesn't keep moving once you're standing in it.
struct ThemeBackdrop: View {
    private let theme: ComicTheme
    private let overrideTint: Color?
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// Detects a theme from a character/series name (falling back to that collection's own cover
    /// color) -- the path `SeriesGroupGridView`/`LibraryGridView` use.
    init(name: String?, color: Color?) {
        theme = ComicTheme.detect(name: name, color: color)
        overrideTint = color
    }

    /// Renders an already-known theme directly -- the path `ambientBackground()`/
    /// `libraryAmbientBackground()` use for the non-series default themes, which don't need any
    /// name/color detection at all.
    init(theme: ComicTheme, tint: Color? = nil) {
        self.theme = theme
        overrideTint = tint
    }

    private var tint: Color { overrideTint ?? theme.accentColor }

    var body: some View {
        ZStack {
            if theme.environment.backgroundTint.isEmpty {
                Design.appBackground
            } else {
                // The theme's actual room color -- a real gradient, not a wash blended over the
                // neutral base. A blend reads fine for warm/saturated themes but disappears for
                // cool-toned ones close in hue to the base itself (e.g. Batman's blue-gray against
                // the app's own near-black blue-gray) -- replacing stays visible for every hue.
                LinearGradient(colors: theme.environment.backgroundTint, startPoint: .top, endPoint: .bottom)
            }
            if colorSchemeContrast != .increased {
                HalftoneTexture(tint: Design.textPrimary, opacity: 0.03)
                vignette
                if let effect = theme.environment.ambientEffect {
                    AmbientEffectView(effect: effect, tint: tint)
                } else {
                    spotlightWash
                }
            }
        }
        .ignoresSafeArea()
        .opacity(appeared || reduceMotion ? 1 : 0)
        .animation(.easeInOut(duration: reduceMotion ? 0 : theme.interaction.transitionDuration), value: theme.id)
        .onAppear {
            withAnimation(.easeInOut(duration: theme.interaction.transitionDuration)) { appeared = true }
        }
    }

    /// A gentle darkening toward the edges -- part of the one shared base look every screen gets,
    /// not a per-theme effect, which is what gives the "premium, elegant" foundation the
    /// environment washes sit on top of.
    private var vignette: some View {
        RadialGradient(colors: [.clear, Color.black.opacity(0.16)],
                       center: .center, startRadius: 320, endRadius: 780)
            .allowsHitTesting(false)
    }

    /// The theme's own spotlight, shaped and sized per `SpotlightStyle` -- a hint of directional
    /// light, not a wash that competes with the covers themselves. Only shown when the theme has
    /// no `ambientEffect` of its own, so a themed screen never carries both at once.
    @ViewBuilder
    private var spotlightWash: some View {
        let spotlight = theme.interaction.spotlight
        let baseOpacity = 0.10 * spotlight.intensity
        switch spotlight.shape {
        case .bloom:
            RadialGradient(colors: [tint.opacity(baseOpacity), tint.opacity(0)],
                           center: .top, startRadius: 0, endRadius: 560)
        case .beam:
            RadialGradient(colors: [tint.opacity(baseOpacity * 1.2), tint.opacity(0)],
                           center: UnitPoint(x: 0.8, y: -0.1), startRadius: 0, endRadius: 640)
        case .glow:
            RadialGradient(colors: [tint.opacity(baseOpacity * 0.8), tint.opacity(0)],
                           center: .top, startRadius: 0, endRadius: 820)
        }
    }
}

/// The shared renderer for the `AmbientEffect` vocabulary -- one case per reusable primitive, not
/// one per theme. Every case is deliberately confined to a small region (never full-screen),
/// rendered at very low opacity, and drawn once at a fixed resting position -- no drift, no
/// looping animation, so this costs nothing extra on every frame. This is the piece a genuinely
/// new visual idea (not just a new combination of existing ones) would extend.
private struct AmbientEffectView: View {
    let effect: AmbientEffect
    let tint: Color

    var body: some View {
        switch effect {
        case .mist:
            ForEach(0..<2, id: \.self) { i in
                Ellipse().fill(Design.textPrimary.opacity(0.05))
                    .frame(width: 240, height: 46)
                    .position(x: CGFloat(700 - i * 90), y: CGFloat(90 + i * 50))
                    .blur(radius: 20)
            }
        case .rain:
            Canvas { context, size in
                for i in 0..<24 {
                    let x = CGFloat(i % 12) * 30
                    let y0 = CGFloat(i / 12) * 90
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: y0))
                    path.addLine(to: CGPoint(x: x - 3, y: y0 + 14))
                    context.stroke(path, with: .color(Design.textPrimary.opacity(0.04)), lineWidth: 1)
                }
            }
            .frame(width: 340, height: 200)
            .position(x: 780, y: 130)
        case .skyline:
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<8, id: \.self) { i in
                    Rectangle().fill(Design.textPrimary.opacity(0.06))
                        .frame(width: 26, height: CGFloat(26 + (i * 41) % 70))
                }
            }
            .frame(width: 260, alignment: .leading)
            .position(x: 200, y: 760)
        case .clouds:
            ForEach(0..<2, id: \.self) { i in
                Ellipse().fill(tint.opacity(0.08))
                    .frame(width: CGFloat(240 + i * 60), height: 54)
                    .position(x: CGFloat(680 + i * 140), y: 112)
                    .blur(radius: 16)
            }
        case .streak:
            ForEach(0..<2, id: \.self) { i in
                Rectangle().fill(tint.opacity(0.10))
                    .frame(width: 2, height: 200)
                    .rotationEffect(.degrees(-30))
                    .position(x: CGFloat(680 + i * 90), y: 30)
            }
        case .stars:
            ForEach(0..<10, id: \.self) { i in
                Circle().fill(Color.white.opacity(0.4))
                    .frame(width: CGFloat(1 + (i % 2)), height: CGFloat(1 + (i % 2)))
                    .position(x: CGFloat(600 + (i * 43) % 360), y: CGFloat(30 + (i * 29) % 220))
            }
        case .grid:
            Canvas { context, size in
                let spacing: CGFloat = 40
                var x: CGFloat = 0
                while x < size.width {
                    context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                    with: .color(tint.opacity(0.06)), lineWidth: 1)
                    x += spacing
                }
            }
            .frame(width: 340, height: 200)
            .position(x: 780, y: 130)
        case .grain:
            Canvas { context, size in
                for i in 0..<40 {
                    let x = CGFloat(i % 20) * 17
                    let y = CGFloat(i / 20) * 40
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                                 with: .color(.white.opacity(0.05)))
                }
            }
            .frame(width: 340, height: 200)
            .position(x: 780, y: 130)
        }
    }
}

extension View {
    /// The card chrome repeated across Stats' `DashboardCard`, and now the recap-sheet tiles/rows
    /// below (`RecapStatTile`, `RecapHighlightRow`, both `YearInReviewView` and
    /// `SeriesCompleteView` share these) -- one definition instead of the same background/clip/
    /// overlay chain copy-pasted at each.
    func dashboardCardStyle(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
            .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(Design.borderColor, lineWidth: 1))
    }

    /// One elevation step above `dashboardCardStyle` -- `surfaceBg` instead of `cardBg`, plus a
    /// visible shadow, for the handful of spots (hero sections, modal chrome) that want to read as
    /// raised above the surrounding cards rather than flush with them.
    func elevatedCardStyle(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.surfaceBg)
            .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
            .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(Design.borderColor, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
    }

    /// The default global theme for non-series screens -- `Design.appBackground`'s flat fill plus
    /// a very subtle top-lit wash, instead of a flat, lightless charcoal. Thin wrapper around
    /// `ThemeBackdrop(theme: .neutral, tint:)`, kept as its own named function so call sites don't
    /// need to know about the theme system's types. `tint` defaults to the neutral warm wash --
    /// pass e.g. `Design.publisherColor(pub)` when browsing is scoped to one publisher, so that
    /// section reads as visibly its own (Marvel red, DC blue...) instead of the whole app
    /// defaulting to the same gold everywhere.
    func ambientBackground(tint: Color = Design.warmSpotlightDefault) -> some View {
        background(ThemeBackdrop(theme: .neutral, tint: tint))
    }

    /// The main library's own default theme -- `.library` in the same `ComicTheme` registry
    /// every series theme comes from, not a separate parallel system. Adds a shelf-edge line
    /// (with a soft shadow under it, like covers are really sitting on something).
    func libraryAmbientBackground(tint: Color = Design.warmSpotlightDefault) -> some View {
        background(ThemeBackdrop(theme: .library, tint: tint))
    }
}

/// One shared empty-state presentation -- previously 5+ near-identical icon/title/message VStacks
/// (`LibraryView` ×3, `YearInReviewView`, `ContentView`'s Runs/Tier Lists placeholders), each with
/// its own slightly different spacing/font/opacity choices. Landing on an empty section now gets a
/// small fade + scale-up on appear (`easeStandard`, not a spring -- matches the "no bounce" rule
/// established for hover/navigation motion) instead of an instant, inert cut.
struct EmptyStateView<Action: View>: View {
    let icon: String
    let title: String
    var message: String? = nil
    var iconFont: Font = Design.Typography.emptyStateIcon
    var messageWidth: CGFloat = 340
    /// Overrides the SF Symbol + halftone patch entirely when present -- for the handful of empty
    /// states (library-empty, no-search-results) where a small themed illustration earns its
    /// keep over a generic system glyph. `nil` (the default) keeps every other call site exactly
    /// as it was.
    var illustration: AnyView? = nil
    @ViewBuilder var action: () -> Action

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            if let illustration {
                illustration
            } else {
                Image(systemName: icon)
                    .font(iconFont)
                    .foregroundStyle(.quaternary)
                    .background(
                        // A small patch of halftone behind just the icon, not the whole empty
                        // state -- texture as a focal accent, not wallpaper.
                        HalftoneTexture(tint: Design.textPrimary, opacity: 0.05)
                            .frame(width: 120, height: 120)
                            .mask(RadialGradient(colors: [.black, .clear], center: .center, startRadius: 0, endRadius: 60))
                    )
            }
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: messageWidth)
            }
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear { withAnimation(Design.easeStandard) { appeared = true } }
    }
}

/// The "shop signage" treatment for the app's kerned all-caps section/screen headers -- previously
/// ~14 near-identical `Text(_.uppercased()).font(.system(size:weight:.black)).kerning(_)` call
/// sites (`LibraryView`'s shelf-row labels, `RunsView`, `DiaryView`, `TierListsView`,
/// `FavoriteMomentsView`, `ReadingHistoryView`, `StatsView`, `YearInReviewView`), each spelled out
/// individually with the plain system font. `OnboardingView` already uses `.rounded` design for
/// its equivalent headers -- this brings the rest of the app's signage in line with that existing
/// "friendlier, branded" voice rather than inventing a new one. Each call site keeps its own
/// existing size/kerning/tint (this doesn't force a single uniform size), only the font design and
/// component ownership are consolidated.
struct SignageLabel: View {
    let text: String
    var size: CGFloat = 13
    var kerning: CGFloat = 1.5
    var tint: Color = Design.secondaryLabel

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .black, design: .rounded))
            .foregroundStyle(tint)
            .kerning(kerning)
    }
}

/// A stack of comic long boxes (the real, generic collector's-storage term -- not any owned
/// design), a couple of faint wall cracks, and a few dust motes drifting slowly through the
/// light -- the library's own "nothing here yet" illustration, standing in for the plain SF
/// Symbol other empty states still use. Only one instance of this exists on screen at a time (an
/// empty state is inherently singular), so the slow drift animation here doesn't carry the same
/// "many cards, many animations" cost the grid's hover effects have to avoid.
struct LongBoxesIllustration: View {
    @State private var driftUp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Canvas { context, size in
                var crack = Path()
                crack.move(to: CGPoint(x: size.width * 0.15, y: 0))
                crack.addLine(to: CGPoint(x: size.width * 0.25, y: size.height * 0.35))
                crack.addLine(to: CGPoint(x: size.width * 0.18, y: size.height * 0.6))
                context.stroke(crack, with: .color(Design.textPrimary.opacity(0.06)), lineWidth: 1.5)

                var crack2 = Path()
                crack2.move(to: CGPoint(x: size.width * 0.85, y: size.height))
                crack2.addLine(to: CGPoint(x: size.width * 0.75, y: size.height * 0.7))
                crack2.addLine(to: CGPoint(x: size.width * 0.8, y: size.height * 0.45))
                context.stroke(crack2, with: .color(Design.textPrimary.opacity(0.06)), lineWidth: 1.5)
            }

            VStack(spacing: 4) {
                longBox(width: 110, tint: Color(red: 0.55, green: 0.42, blue: 0.28))
                longBox(width: 96, tint: Color(red: 0.62, green: 0.48, blue: 0.32))
            }

            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Design.warmSpotlightDefault.opacity(0.5))
                    .frame(width: CGFloat(3 + i), height: CGFloat(3 + i))
                    .offset(x: CGFloat(-30 + i * 28), y: (driftUp ? -14 : 6) + CGFloat(i * 8))
                    .opacity(driftUp ? 0.15 : 0.55)
            }
        }
        .frame(width: 140, height: 100)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { driftUp = true }
        }
        .accessibilityHidden(true)
    }

    private func longBox(width: CGFloat, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(tint)
            .frame(width: width, height: 26)
            .overlay(alignment: .top) {
                Rectangle().fill(Design.brandGold.opacity(0.7)).frame(height: 5)
                    .padding(.horizontal, 8)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.2), lineWidth: 1))
    }
}

/// A speech bubble with a "?" -- the illustration for a "no search results" empty state, standing
/// in for the plain magnifying-glass SF Symbol.
struct SpeechBubbleQuestionIllustration: View {
    var body: some View {
        ZStack {
            SpeechBubbleShape()
                .fill(Design.surfaceBg)
                .overlay(SpeechBubbleShape().stroke(Design.borderColor, lineWidth: 1.5))
            Text("?")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(.tertiary)
                .offset(y: -8)
        }
        .frame(width: 88, height: 70)
        .accessibilityHidden(true)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(icon: String, title: String, message: String? = nil, iconFont: Font = Design.Typography.emptyStateIcon, messageWidth: CGFloat = 340, illustration: AnyView? = nil) {
        self.init(icon: icon, title: title, message: message, iconFont: iconFont, messageWidth: messageWidth, illustration: illustration, action: { EmptyView() })
    }
}

/// Shared by both recap sheets (`YearInReviewView`, `SeriesCompleteView`) -- previously an
/// identical `statTile(_:value:icon:)` copy-pasted in each, differing only in whether the icon
/// tint was a fixed color or the series' own accent color.
struct RecapStatTile: View {
    let label: String
    let value: String
    let icon: String
    var tint: Color = Design.brandGold

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 24, weight: .black)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).kerning(0.5)
        }
        .dashboardCardStyle(padding: 16)
    }
}

/// Shared by both recap sheets -- previously an identical `highlightRow(icon:label:value:detail:)`
/// copy-pasted in each.
struct RecapHighlightRow: View {
    let icon: String
    let label: String
    let value: String
    var detail: String? = nil
    var tint: Color = Design.brandGold

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .dashboardCardStyle(padding: 14)
    }
}

extension Image {
    /// The one standard way a comic's own cover art is displayed anywhere in the app: the full
    /// image, always -- never cropped to force-fill a card's box. Callers still supply their own
    /// `.frame(...)` for the box size; a cover whose real aspect ratio doesn't match that box
    /// simply letterboxes/pillarboxes within it rather than losing part of the artwork.
    func comicCoverStyle() -> some View {
        self.resizable().aspectRatio(contentMode: .fit)
    }
}

private struct HoverLiftModifier: ViewModifier {
    let scale: CGFloat
    var duration: Double = 0.15
    var externalIsHovered: Binding<Bool>? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var internalIsHovered = false

    private var isHovered: Bool { externalIsHovered?.wrappedValue ?? internalIsHovered }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && !reduceMotion ? scale : 1.0)
            // A spring here (even a "snappy" one) overshoots and settles with a visible
            // wobble -- across a grid where onHover fires rapidly as the cursor crosses card
            // after card, that reads as the whole grid shaking. A plain ease has zero overshoot.
            // `duration` is the one place a theme's pace shows -- Batman settles slower than Flash.
            .animation(Design.motion(.easeOut(duration: duration), reduce: reduceMotion), value: isHovered)
            .onHover { hovering in
                if let externalIsHovered { externalIsHovered.wrappedValue = hovering }
                else { internalIsHovered = hovering }
            }
    }
}

struct GoldCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(
                Design.goldGradient.opacity(configuration.isPressed ? 0.75 : 1)
            )
            .clipShape(Capsule())
            .shadow(color: Design.brandGold.opacity(0.35), radius: 8, x: 0, y: 3)
            .contentShape(Capsule())
    }
}

struct StarRating: View {
    let rating: Int
    var size: CGFloat = 12
    var unfilledColor: Color = Design.secondaryLabel
    let onTap: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(star <= rating ? Design.brandGold : unfilledColor)
                    .overlay(
                        Rectangle().fill(Color.clear).frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(star) }
                    )
                    .help(star == rating ? "Tap to clear rating" : "Rate \(star) star\(star == 1 ? "" : "s")")
                    .accessibilityLabel(star == rating ? "Clear rating" : "Rate \(star) star\(star == 1 ? "" : "s")")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }
}

struct TagChip: View {
    let name: String
    var category: String? = nil
    var onRemove: (() -> Void)? = nil

    private var tint: Color {
        switch TagCategory(rawValue: category ?? "") {
        case .genre:  return Design.brandGold
        case .mood:   return .purple
        case .format: return .teal
        case .custom, nil: return Design.brandBlue
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(name)").font(.caption)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(name)")
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(tint.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.3)))
    }
}

struct PublisherBadge: View {
    let publisher: String

    var body: some View {
        Text(publisher.uppercased())
            .font(.system(size: 9, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Design.publisherColor(publisher))
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.sm))
            .shadow(color: Design.publisherColor(publisher).opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

struct StarRatingLarge: View {
    let rating: Int
    let onTap: (Int) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: 20))
                    .foregroundStyle(star <= rating ? Design.brandGold : Design.secondaryLabel)
                    .overlay(
                        Rectangle().fill(Color.clear).frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(star) }
                    )
                    .help(star == rating ? "Tap to clear rating" : "Rate \(star) star\(star == 1 ? "" : "s")")
                    .accessibilityLabel(star == rating ? "Clear rating" : "Rate \(star) star\(star == 1 ? "" : "s")")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rating: \(rating == 0 ? "None" : "\(rating) star\(rating == 1 ? "" : "s")")")
    }
}

#Preview("Publisher Badge") {
    HStack(spacing: 12) {
        ForEach(["DC", "Marvel", "Manga", "Indie", "Other"], id: \.self) { pub in
            PublisherBadge(publisher: pub)
        }
    }
    .padding(24).background(Design.appBackground).preferredColorScheme(.dark)
}

#Preview("Star Ratings") {
    HStack(spacing: 20) {
        ForEach([0, 2, 4, 5], id: \.self) { r in
            StarRatingLarge(rating: r) { _ in }
        }
    }
    .padding(24).background(Design.appBackground).preferredColorScheme(.dark)
}

#Preview("Gold Button") {
    Button("Add to Reading List") {}
        .goldButton()
        .padding(24).background(Design.appBackground).preferredColorScheme(.dark)
}
