import SwiftUI

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
