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
    static let groupCardHeight: CGFloat = 310
    static let cardCorner:      CGFloat = 10
    static let gridSpacing:     CGFloat = 22

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
    func comicCardStyle() -> some View {
        self
            .clipShape(Rectangle())
            .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 4)
    }

    func goldButton() -> some View {
        self
            .buttonStyle(GoldCapsuleStyle())
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
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
