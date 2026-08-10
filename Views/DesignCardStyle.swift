import SwiftUI

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
