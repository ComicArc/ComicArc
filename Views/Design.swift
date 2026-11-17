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

    /// Clamps a cover-derived color into a saturation/brightness band, so it works stretched across
    /// a large area.
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

    /// A low-saturation, near-black version of this color, for the reader backdrop.
    func clampedForDeepBackdrop() -> Color { clamped(saturation: 0.25...0.45, brightness: 0.05...0.12) }
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
    static let groupCardHeight: CGFloat = 330
    static let cardCorner:      CGFloat = 10
    static let gridSpacing:     CGFloat = 22

    enum Radius {
        static let sm: CGFloat = 4
    }

    /// Named large display font sizes.
    enum Typography {
        static let heroNumber    = Font.system(size: 64, weight: .black, design: .rounded)
        static let heroSeal      = Font.system(size: 40, weight: .regular)
        static let emptyStateIcon = Font.system(size: 52, weight: .regular)

        /// Small row-metadata text sizes.
        static let microLabel     = Font.system(size: 10)
        static let microGlyph     = Font.system(size: 9)
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

    /// Hover glow tint used until a cover's accent color loads.

    static var textPrimary: Color { AppTheme.current.isLight ? Color(red: 0.13, green: 0.11, blue: 0.08) : .white }

    static var goldGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.980, green: 0.749, blue: 0.118),
                     Color(red: 0.855, green: 0.580, blue: 0.047)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    static let springGentle   = Animation.spring(response: 0.5, dampingFraction: 0.85)
    static let easeStandard   = Animation.easeInOut(duration: 0.2)
    static let easeFast       = Animation.easeOut(duration: 0.15)

    static func motion(_ animation: Animation, reduce: Bool) -> Animation {
        reduce ? .default : animation
    }

    /// The system Reduce Motion setting, for animations started outside views. Views should use
    /// `@Environment(\.accessibilityReduceMotion)`.
    static var systemReduceMotionEnabled: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// Plain black when Increase Contrast or Differentiate Without Color is on.
    static func deepBackdropTint(_ color: Color?, increaseContrast: Bool, differentiateWithoutColor: Bool) -> Color {
        guard !increaseContrast, !differentiateWithoutColor, let color else { return .black }
        return color.clampedForDeepBackdrop()
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
    /// Card chrome for Stats and the recap sheets.
    func dashboardCardStyle(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
            .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(Design.borderColor, lineWidth: 1))
    }

    func ambientBackground() -> some View {
        background(Design.appBackground.ignoresSafeArea())
    }

    /// Cover chrome: a soft shadow at rest, a ring and shadow tinted by the cover's accent color on
    /// hover.
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

    /// The hover-scale effect shared by every library card. Pass `isHovered:` to also read the
    /// state.
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
            // A plain ease, not a spring: springs overshoot and make the grid look like it's
            // shaking.
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

struct EmptyStateView<Action: View>: View {
    let icon: String
    let title: String
    var message: String? = nil
    var iconFont: Font = Design.Typography.emptyStateIcon
    var messageWidth: CGFloat = 340
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(iconFont)
                .foregroundStyle(.quaternary)
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
    }
}

/// Kerned all-caps header style used for section and screen titles.
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

extension EmptyStateView where Action == EmptyView {
    init(icon: String, title: String, message: String? = nil, iconFont: Font = Design.Typography.emptyStateIcon, messageWidth: CGFloat = 340) {
        self.init(icon: icon, title: title, message: message, iconFont: iconFont, messageWidth: messageWidth, action: { EmptyView() })
    }
}

/// Stat tile shared by the recap sheets.
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

/// Highlight row shared by the recap sheets.
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
    /// Shows the full cover, letterboxed if needed, never cropped. Callers set the frame.
    func comicCoverStyle() -> some View {
        self.resizable().aspectRatio(contentMode: .fit)
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

/// The app's mark: a comic "impact burst", drawn as a Shape so it scales and tints cleanly.
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
