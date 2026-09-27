import SwiftUI

/// One shared empty-state presentation: icon, title, optional message and action.
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

/// The "shop signage" treatment for the app's kerned all-caps section/screen headers -- previously
/// ~14 near-identical `Text(_.uppercased()).font(.system(size:weight:.black)).kerning(_)` call
/// sites (`LibraryView`'s shelf-row labels, `RunsView`,
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

extension EmptyStateView where Action == EmptyView {
    init(icon: String, title: String, message: String? = nil, iconFont: Font = Design.Typography.emptyStateIcon, messageWidth: CGFloat = 340) {
        self.init(icon: icon, title: title, message: message, iconFont: iconFont, messageWidth: messageWidth, action: { EmptyView() })
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

#Preview("Publisher Badge") {
    HStack(spacing: 12) {
        ForEach(["DC", "Marvel", "Manga", "Indie", "Other"], id: \.self) { pub in
            PublisherBadge(publisher: pub)
        }
    }
    .padding(24).background(Design.appBackground).preferredColorScheme(.dark)
}

#Preview("Gold Button") {
    Button("Add to Reading List") {}
        .goldButton()
        .padding(24).background(Design.appBackground).preferredColorScheme(.dark)
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
