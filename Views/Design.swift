import SwiftUI

// MARK: - Grid density

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
    // Card sizes — read via GridDensity at runtime; these are the .regular defaults
    static let cardWidth:       CGFloat = 172
    static let cardHeight:      CGFloat = 258
    static let groupCardWidth:  CGFloat = 220
    static let groupCardHeight: CGFloat = 310
    static let cardCorner:      CGFloat = 10
    static let gridSpacing:     CGFloat = 22

    // Dark palette — deeper than before for more contrast
    static let appBackground = Color(red: 0.046, green: 0.048, blue: 0.074)  // #0c0d13
    static let navBackground = Color(red: 0.065, green: 0.068, blue: 0.102)  // #111118
    static let cardBg        = Color(red: 0.088, green: 0.092, blue: 0.132)  // #161722
    static let surfaceBg     = Color(red: 0.108, green: 0.114, blue: 0.162)  // #1c1d2a
    static let borderColor   = Color.white.opacity(0.09)

    // Brand — warmer amber gold, richer blue
    static let secondaryLabel = Color.secondary
    static let brandBlue      = Color(red: 0.173, green: 0.431, blue: 0.847)  // #2C6ED8
    static let brandGold      = Color(red: 0.918, green: 0.659, blue: 0.082)  // #EAA815 — warmer

    // Gold gradient (use for prominent elements)
    static var goldGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.980, green: 0.749, blue: 0.118),
                     Color(red: 0.855, green: 0.580, blue: 0.047)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // Spring animation constants
    static let springSnappy   = Animation.spring(response: 0.3, dampingFraction: 0.75)
    static let springBouncy   = Animation.spring(response: 0.4, dampingFraction: 0.65)
    static let springGentle   = Animation.spring(response: 0.5, dampingFraction: 0.85)
    static let easeStandard   = Animation.easeInOut(duration: 0.2)
    static let easeFast       = Animation.easeOut(duration: 0.15)

    // Reduced-motion–aware animation: returns `.default` (instant) when reduce-motion is on.
    // Usage: `Design.motion(.springSnappy, env: reduceMotion)`
    static func motion(_ animation: Animation, reduce: Bool) -> Animation {
        reduce ? .default : animation
    }

    // Publisher color map
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

// MARK: - Progress format

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

// MARK: - View modifiers

extension View {
    func comicCardStyle() -> some View {
        self
            .clipShape(Rectangle())
            .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 4)
    }

    func darkSurface(cornerRadius: CGFloat = 10) -> some View {
        self
            .background(Design.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Design.borderColor, lineWidth: 1))
    }

    func goldButton() -> some View {
        self
            .buttonStyle(GoldCapsuleStyle())
    }
}

// MARK: - Gold button style

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

// MARK: - Star rating

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

// MARK: - Publisher badge (colored pill, matches Python app)

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

// MARK: - Previews (use for rapid UI iteration without rebuilding)

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
