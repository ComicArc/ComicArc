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
    /// resting/unhovered state, so grids never look tinted while just sitting there.
    func comicCardStyle(accentColor: Color? = nil, isHovered: Bool = false) -> some View {
        let tint = isHovered ? accentColor : nil
        return self
            .clipShape(Rectangle())
            .shadow(color: tint?.opacity(0.5) ?? .black.opacity(0.45),
                    radius: tint != nil ? 12 : 8, x: 0, y: tint != nil ? 6 : 4)
    }

    func goldButton() -> some View {
        self
            .buttonStyle(GoldCapsuleStyle())
    }

    /// The hover-scale micro-interaction every card type in the library uses (`ComicCard`,
    /// `GroupCard`, and the shelf cards) -- previously the identical `@State isHovered` +
    /// `.scaleEffect` + `.animation` + `.onHover` triad copy-pasted at each call site. Owns its
    /// own hover state, so a call site just needs this one modifier, nothing else.
    func hoverLift(scale: CGFloat = 1.03) -> some View {
        modifier(HoverLiftModifier(scale: scale))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && !reduceMotion ? scale : 1.0)
            .animation(Design.motion(Design.springSnappy, reduce: reduceMotion), value: isHovered)
            .onHover { isHovered = $0 }
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
    let onTap: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(star <= rating ? Design.brandGold : Design.secondaryLabel)
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
