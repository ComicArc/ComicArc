import SwiftUI

struct ComicCard: View {
    let comic:      Comic
    let isSelected: Bool
    let onOpen:     () -> Void
    var cardWidth:  CGFloat = Design.cardWidth
    var cardHeight: CGFloat = Design.cardHeight

    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fileService) private var fileService
    @State private var thumbnail: PlatformImage?
    @State private var isHovered = false

    private var isBulkSelected: Bool { vm.selectedComicIds.contains(comic.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                cover
                    .frame(width: cardWidth, height: cardHeight)
                    .comicCardStyle()

                if comic.isStarted && !comic.isFinished {
                    progressStrip
                }
            }
            .overlay(alignment: .topTrailing) {
                if comic.isFavorite && !vm.bulkMode {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red).font(.caption)
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if vm.bulkMode {
                    Image(systemName: isBulkSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isBulkSelected ? Color.accentColor : .white)
                        .shadow(radius: 2)
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if comic.isFinished && !vm.bulkMode { finishedBadge }
            }

            Text(comic.title)
                .font(.caption).lineLimit(2)
                .frame(width: cardWidth, alignment: .leading)

            PublisherBadge(publisher: comic.publisher)

            if comic.rating > 0 && !vm.bulkMode {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= comic.rating ? "star.fill" : "star")
                            .font(.system(size: 8))
                            .foregroundStyle(i <= comic.rating ? Design.brandGold : Design.secondaryLabel)
                    }
                }
            }
        }
        .scaleEffect(isHovered && !reduceMotion ? 1.03 : 1.0)
        .animation(Design.motion(Design.springSnappy, reduce: reduceMotion), value: isHovered)
        .overlay(
            RoundedRectangle(cornerRadius: Design.cardCorner + 2)
                .stroke(
                    isBulkSelected ? Color.accentColor
                    : isSelected   ? Color.accentColor
                    : Color.clear,
                    lineWidth: 2.5
                )
                .frame(width: cardWidth + 5, height: cardHeight + 5)
        )
        .onHover { isHovered = $0 }
        .gesture(
            TapGesture(count: 2).onEnded {
                if !vm.bulkMode { onOpen() }
            }
        )
        .contextMenu { contextMenu }
        .onAppear { loadThumbnail() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(vm.bulkMode ? "Double-tap to toggle selection" : "Double-tap to open")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open") { if !vm.bulkMode { onOpen() } }
        .accessibilityAction(named: comic.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            LibraryViewModel.shared.toggleFavorite(comic)
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var cover: some View {
        ZStack {
            Design.cardBg
            if let img = thumbnail {
                Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                    Text(comic.series).font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 4)
                }
            }
        }
    }

    private var progressStrip: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.35)).frame(height: 4)
                Rectangle().fill(Color.accentColor)
                    .frame(width: cardWidth * comic.progressPercent, height: 4)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .allowsHitTesting(false)
    }

    private var finishedBadge: some View {
        ZStack {
            Circle().fill(Color.green).frame(width: 22, height: 22)
            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
        }
        .padding(6)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if vm.bulkMode {
            Button(isBulkSelected ? "Deselect" : "Select") { vm.toggleSelection(comic.id) }
            Button("Select All") { vm.selectAll() }
            Divider()
            Button("Exit Selection Mode") { vm.toggleBulkMode() }
        } else {
            Button("Read") { onOpen() }
            Button("View Details") { vm.selectedComic = comic }

            Divider()

            Button(comic.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                LibraryViewModel.shared.toggleFavorite(comic)
            }
            Button(comic.inReadingList ? "Remove from Reading List" : "Add to Reading List") {
                LibraryViewModel.shared.toggleReadingList(comic)
            }

            Divider()

            if comic.isFinished {
                Button("Mark as Unread") { LibraryViewModel.shared.markUnread(comic) }
            } else {
                Button("Mark as Read")   { LibraryViewModel.shared.markRead(comic) }
            }

            Divider()

            Button("Set as Series Cover") { LibraryViewModel.shared.setSeriesCover(comic) }
            Button("Select Multiple")     { vm.toggleBulkMode() }

            Divider()

            #if os(macOS)
            Button("Show in Finder") {
                fileService.revealInFinder(URL(fileURLWithPath: comic.filePath))
            }
            #endif
            ShareLink("Share", item: URL(fileURLWithPath: comic.filePath))

            Divider()

            Button("Delete", role: .destructive) { LibraryViewModel.shared.delete([comic]) }
        }
    }

    private var accessibilityDescription: String {
        var parts = [comic.title, comic.series, comic.publisher]
        if comic.rating > 0 { parts.append("\(comic.rating) stars") }
        if comic.isFinished { parts.append("Finished") }
        else if comic.isStarted { parts.append("Page \(comic.progress + 1) of \(comic.pageCount)") }
        else { parts.append("Unread") }
        if comic.isFavorite { parts.append("Favorited") }
        if vm.bulkMode { parts.append(isBulkSelected ? "Selected" : "Not selected") }
        return parts.joined(separator: ", ")
    }

    private func loadThumbnail() {
        ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 }
    }
}
