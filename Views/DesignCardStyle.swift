import SwiftUI

extension View {
    /// The card chrome shared by Stats' `DashboardCard` and the recap-sheet tiles/rows.
    func dashboardCardStyle(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
            .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(Design.borderColor, lineWidth: 1))
    }

    /// The one plain page background every screen uses.
    func ambientBackground() -> some View {
        background(Design.appBackground.ignoresSafeArea())
    }

    /// Cover card chrome: a soft drop shadow at rest; on hover, a thin ring and shadow tinted
    /// from the cover's own accent color (when known).
    func comicCardStyle(accentColor: Color? = nil, isHovered: Bool = false) -> some View {
        let hoverTint = isHovered ? (accentColor ?? Design.brandGold) : nil
        return self
            .clipShape(Rectangle())
            .shadow(color: hoverTint?.opacity(0.45) ?? .black.opacity(0.45),
                    radius: hoverTint != nil ? 14 : 8, x: 0, y: hoverTint != nil ? 8 : 4)
            .overlay(Rectangle().stroke(hoverTint?.opacity(0.6) ?? .clear, lineWidth: 1.5))
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
            .background(Rectangle().fill(Design.goldGradient).opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(Capsule())
            .shadow(color: Design.brandGold.opacity(0.35), radius: 8, x: 0, y: 3)
            .contentShape(Capsule())
    }
}
