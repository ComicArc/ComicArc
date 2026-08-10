import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
