import SwiftUI

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
                    ForEach(vm.inProgressComics.dropFirst()) { comic in
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
            SignageLabel(text: "Read Next", size: 13, kerning: 1.5, tint: Design.textPrimary)
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
                .comicCardStyle(accentColor: accentColor, isHovered: isHovered)

                if comic.isStarted && !comic.isFinished {
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

            Text(shelfDetail)
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .hoverLift(scale: 1.04, isHovered: $isHovered)
        .onAppear {
            ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 }
            ThumbnailCache.shared.accentColor(for: comic) { accentColor = $0 }
        }
        .contextMenu {
            Button(comic.isStarted ? "Continue Reading" : "Read") { vm.openReader(comic) }
            Divider()
            Button("Mark as Read") { vm.markRead(comic) }
            Button("Metadata Inspector…") { showMetadataInspector = true }
        }
        .sheet(isPresented: $showMetadataInspector) { MetadataInspectorView(comicId: comic.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(comic.title)
        .accessibilityValue(comic.isStarted
            ? "Page \(comic.progress + 1) of \(comic.pageCount), \(Int(comic.progressPercent * 100))% complete"
            : "Unread")
        .accessibilityHint(comic.isStarted ? "Double-tap to continue reading" : "Double-tap to start reading")
        .accessibilityAddTraits(.isButton)
    }

    /// Page progress for something you're partway through; the issue number (or series) for an
    /// unstarted Read Next suggestion, which would otherwise read "p. 1/24".
    private var shelfDetail: String {
        if comic.isStarted { return "p. \(comic.progress + 1)/\(comic.pageCount)" }
        if let issue = comic.issueNumber, !issue.isEmpty { return "\(comic.series) #\(issue)" }
        return comic.series
    }
}
