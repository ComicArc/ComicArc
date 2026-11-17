import SwiftUI

/// A large featured cover for the comic you're currently reading, over a blurred copy of its cover
/// and tinted by its color.
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
        // A `.background()` so the GeometryReader gets this view's size, not the ScrollView's
        // unbounded height.
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

    /// The cover blurred behind a dark scrim, so the text stays readable.
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

    /// Page progress if started; otherwise the issue number or series.
    private var shelfDetail: String {
        if comic.isStarted { return "p. \(comic.progress + 1)/\(comic.pageCount)" }
        if let issue = comic.issueNumber, !issue.isEmpty { return "\(comic.series) #\(issue)" }
        return comic.series
    }
}
