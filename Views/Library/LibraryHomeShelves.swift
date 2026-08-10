import SwiftUI

/// The one genuinely loud moment in the app -- everything else in this design pass (spotlight
/// hover, shop-floor wash, halftone) was deliberately kept to a whisper so restraint elsewhere
/// would read as restraint, not blandness. This is the payoff: the front-window display, sized
/// and saturated well past what any card in a scrolling grid gets, for the one comic that
/// actually deserves it -- whatever was most recently read. Tints itself from that comic's own
/// cover color (falling back to its publisher's color, never the neutral gold default), so the
/// A larger featured cover for whatever was most recently read -- sized past what any card in a
/// scrolling grid gets, since this is the one comic that actually deserves the extra attention.
/// Tints itself from that comic's own cover color (falling back to its publisher's color, never
/// the neutral gold default), so the one enlarged moment in the library is also its most personal
/// one, not another gold accent.
///
/// The cover art is the actual centerpiece, "Now Playing"-style (matches Apple Music/TV's own
/// hero pattern rather than inventing a new one): the same cover, heavily blurred, fills the whole
/// band as an ambient backdrop behind a dark scrim, while the sharp cover stays the sole focal
/// point in front. No hover-tracking tilt, no extra ribbon/texture layered on top -- the enlarged
/// cover and its own color are the whole effect.
struct NowReadingHero: View {
    let comic: Comic
    @EnvironmentObject var vm: LibraryViewModel
    @State private var thumbnail: PlatformImage?
    @State private var accentColor: Color?

    private var tint: Color { accentColor ?? Design.publisherColor(comic.publisher) }
    private let coverWidth: CGFloat = 180
    private let coverHeight: CGFloat = 270

    var body: some View {
        Button {
            vm.openReader(comic)
        } label: {
            HStack(alignment: .center, spacing: 28) {
                cover
                details
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `backdrop` as a `.background()`, not a `ZStack` sibling -- a `GeometryReader` sibling
        // inside a `ScrollView` would be proposed an unbounded height and blow up to fill it. As
        // a background it's proposed exactly this button's own content-driven size instead.
        .background(backdrop)
        .onAppear {
            ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 }
            ThumbnailCache.shared.accentColor(for: comic) { accentColor = $0 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now Reading: \(comic.title)")
        .accessibilityValue("Page \(comic.progress + 1) of \(comic.pageCount)")
        .accessibilityHint("Double-tap to continue reading")
        .accessibilityAddTraits(.isButton)
    }

    /// The cover, heavily blurred and extended edge-to-edge, behind a dark scrim so foreground
    /// text stays readable -- a single static image, blurred once when it loads, not re-rendered
    /// per frame, so this costs nothing extra during scroll or hover.
    @ViewBuilder
    private var backdrop: some View {
        GeometryReader { geo in
            if let img = thumbnail {
                Image(platformImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: 60)
                    .overlay(Design.appBackground.opacity(0.6))
            } else {
                Design.appBackground
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var cover: some View {
        Group {
            Design.cardBg
            if let img = thumbnail {
                Image(platformImage: img).comicCoverStyle()
                    .frame(width: coverWidth, height: coverHeight)
            } else {
                Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .frame(width: coverWidth, height: coverHeight)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(tint.opacity(0.5), lineWidth: 1.5))
        .shadow(color: tint.opacity(0.45), radius: 24, x: 0, y: 14)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignageLabel(text: "Now Reading", size: 13, kerning: 1.8, tint: Design.brandGold)
            Text(comic.title)
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(Design.textPrimary)
                .lineLimit(2)
            Text(comic.series)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: comic.progressPercent).tint(tint)
                    .frame(maxWidth: 260)
                Text("Page \(comic.progress + 1) of \(comic.pageCount)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.top, 4)

            HStack(spacing: 6) {
                Text("Continue Reading")
                Image(systemName: "arrow.right")
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 20).padding(.vertical, 9)
            .background(Design.goldGradient)
            .clipShape(Capsule())
            .shadow(color: Design.brandGold.opacity(0.4), radius: 10, x: 0, y: 4)
            .padding(.top, 6)
        }
    }
}

struct ContinueReadingShelf: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "book.open.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Design.brandGold)
                SignageLabel(text: "Continue Reading", size: 13, kerning: 1.5, tint: Design.textPrimary)
            }
            .padding(.horizontal, Design.gridSpacing)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.inProgressComics) { comic in
                        ShelfCard(comic: comic)
                            .onTapGesture { vm.openReader(comic) }
                    }
                }
                .padding(.horizontal, Design.gridSpacing)
            }
        }
        .padding(.top, Design.gridSpacing)
    }
}

struct ReadNextShelf: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Design.brandGold)
                SignageLabel(text: "Read Next", size: 13, kerning: 1.5, tint: Design.textPrimary)
            }
            .padding(.horizontal, Design.gridSpacing)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.readNextSuggestions) { comic in
                        ShelfCard(comic: comic)
                            .onTapGesture { vm.openReader(comic) }
                    }
                }
                .padding(.horizontal, Design.gridSpacing)
            }
        }
        .padding(.top, Design.gridSpacing)
    }
}

struct OnThisDayShelf: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Design.brandGold)
                SignageLabel(text: "On This Day", size: 13, kerning: 1.5, tint: Design.textPrimary)
            }
            .padding(.horizontal, Design.gridSpacing)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.onThisDayEntries) { entry in
                        OnThisDayCard(entry: entry)
                            .onTapGesture { vm.openReader(entry.comic) }
                    }
                }
                .padding(.horizontal, Design.gridSpacing)
            }
        }
        .padding(.top, Design.gridSpacing)
    }
}

struct OnThisDayCard: View {
    let entry: DiaryEntry
    @State private var thumbnail: PlatformImage?
    @State private var accentColor: Color?
    @State private var isHovered = false

    private var yearsAgo: Int {
        let loggedYear = Int(entry.loggedAt.prefix(4)) ?? Calendar.current.component(.year, from: Date())
        return max(1, Calendar.current.component(.year, from: Date()) - loggedYear)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Design.cardBg
                if let img = thumbnail {
                    Image(platformImage: img).comicCoverStyle()
                        .frame(width: 90, height: 130)
                } else {
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 90, height: 130)
            // Hover-only glow, same rule as `ComicCard` -- this is a single comic's cover, not a
            // series/character group, so it stays neutral at rest.
            .comicCardStyle(accentColor: accentColor, isHovered: isHovered, fallbackTint: Design.publisherColor(entry.comic.publisher))

            Text(entry.comic.title)
                .font(.caption2).lineLimit(2)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)

            Text(yearsAgo == 1 ? "1 YEAR AGO" : "\(yearsAgo) YEARS AGO")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Design.brandGold)
        }
        .hoverLift(scale: 1.04, isHovered: $isHovered)
        .shelfTilt(seed: entry.comic.id, isHovered: isHovered)
        .onAppear {
            ThumbnailCache.shared.thumbnail(for: entry.comic) { thumbnail = $0 }
            ThumbnailCache.shared.accentColor(for: entry.comic) { accentColor = $0 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.comic.title)
        .accessibilityValue(yearsAgo == 1 ? "Read 1 year ago today" : "Read \(yearsAgo) years ago today")
        .accessibilityHint("Double-tap to open in reader")
        .accessibilityAddTraits(.isButton)
    }
}

struct RecommendedShelf: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Design.brandGold)
                SignageLabel(text: "Recommended For You", size: 13, kerning: 1.5, tint: Design.textPrimary)
            }
            .padding(.horizontal, Design.gridSpacing)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.recommendations) { comic in
                        RecommendedCard(comic: comic)
                            .onTapGesture { vm.openReader(comic) }
                    }
                }
                .padding(.horizontal, Design.gridSpacing)
            }
        }
        .padding(.top, Design.gridSpacing)
    }
}

struct RecommendedCard: View {
    let comic: Comic
    @State private var thumbnail: PlatformImage?
    @State private var accentColor: Color?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Design.cardBg
                if let img = thumbnail {
                    Image(platformImage: img).comicCoverStyle()
                        .frame(width: 90, height: 130)
                } else {
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 90, height: 130)
            .comicCardStyle(accentColor: accentColor, isHovered: isHovered, fallbackTint: Design.publisherColor(comic.publisher))

            Text(comic.title)
                .font(.caption2).lineLimit(2)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)

            Text(comic.series)
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                .frame(width: 90, alignment: .leading)
        }
        .hoverLift(scale: 1.04, isHovered: $isHovered)
        .shelfTilt(seed: comic.id, isHovered: isHovered)
        .onAppear {
            ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 }
            ThumbnailCache.shared.accentColor(for: comic) { accentColor = $0 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(comic.title)
        .accessibilityValue("From \(comic.series), recommended based on your ratings")
        .accessibilityHint("Double-tap to open in reader")
        .accessibilityAddTraits(.isButton)
    }
}

struct ShelfCard: View {
    let comic: Comic
    @EnvironmentObject var vm: LibraryViewModel
    @State private var thumbnail: PlatformImage?
    @State private var showMetadataInspector = false
    @State private var accentColor: Color?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottom) {
                ZStack {
                    Design.cardBg
                    if let img = thumbnail {
                        Image(platformImage: img).comicCoverStyle()
                            .frame(width: 90, height: 130)
                    } else {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 90, height: 130)
                .comicCardStyle(accentColor: accentColor, isHovered: isHovered, fallbackTint: Design.publisherColor(comic.publisher))

                if !comic.isFinished {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.35)).frame(height: 3)
                        Rectangle().fill(Design.brandBlue)
                            .frame(width: 90 * comic.progressPercent, height: 3)
                    }
                    .frame(width: 90)
                    .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
                }
            }

            Text(comic.title)
                .font(.caption2).lineLimit(2)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)

            Text("p. \(comic.progress + 1)/\(comic.pageCount)")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .hoverLift(scale: 1.04, isHovered: $isHovered)
        .shelfTilt(seed: comic.id, isHovered: isHovered)
        .onAppear {
            ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 }
            ThumbnailCache.shared.accentColor(for: comic) { accentColor = $0 }
        }
        .contextMenu {
            Button("Continue Reading") { vm.readerComic = comic }
            Divider()
            Button("Mark as Read") { vm.markRead(comic) }
            Button("Metadata Inspector…") { showMetadataInspector = true }
        }
        .sheet(isPresented: $showMetadataInspector) { MetadataInspectorView(comicId: comic.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(comic.title)
        .accessibilityValue("Page \(comic.progress + 1) of \(comic.pageCount), \(Int(comic.progressPercent * 100))% complete")
        .accessibilityHint("Double-tap to continue reading")
        .accessibilityAddTraits(.isButton)
    }
}
