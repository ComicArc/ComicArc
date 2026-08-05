import SwiftUI

/// Browses every bookmark flagged as a favorite moment across the whole library -- distinct from
/// the resume-reading position on `Comic`, and from a comic's own per-issue bookmark list, which
/// only shows bookmarks for that one comic. Tapping a row jumps straight into the reader at that
/// exact page via `LibraryViewModel.openReader(_:atPage:)`.
struct FavoriteMomentsView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @State private var moments: [FavoriteMoment] = []
    @State private var isLoading = true

    private var filteredMoments: [FavoriteMoment] {
        guard !vm.searchText.isEmpty else { return moments }
        let q = vm.searchText.lowercased()
        return moments.filter {
            $0.comic.title.lowercased().contains(q) ||
            $0.comic.series.lowercased().contains(q) ||
            $0.comic.publisher.lowercased().contains(q) ||
            $0.bookmark.label.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("HIGHLIGHTS")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Design.brandGold)
                    .kerning(1.5)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if moments.isEmpty {
                EmptyStateView(
                    icon: "star.circle",
                    title: "No Highlights Yet",
                    message: "While reading, open Bookmarks and tap the star on any page worth revisiting."
                )
            } else if filteredMoments.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No Matching Highlights")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredMoments) { moment in
                            momentRow(moment)
                            Rectangle().fill(Design.borderColor).frame(height: 1)
                                .padding(.leading, 24)
                        }
                    }
                }
            }
        }
        .background(Design.appBackground)
        .task { await load() }
    }

    private func momentRow(_ moment: FavoriteMoment) -> some View {
        HStack(spacing: 14) {
            PageThumbnail(comic: moment.comic, page: moment.bookmark.page)
                .frame(width: 54, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text(moment.comic.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    PublisherBadge(publisher: moment.comic.publisher)
                    Text(moment.comic.series)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                Text("Page \(moment.bookmark.page + 1)")
                    .font(.caption2).foregroundStyle(.tertiary)

                if !moment.bookmark.label.isEmpty {
                    Text(moment.bookmark.label)
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Image(systemName: "star.fill").foregroundStyle(Design.brandGold)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { vm.openReader(moment.comic, atPage: moment.bookmark.page) }
        .contextMenu {
            Button("Remove from Highlights") { remove(moment) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(moment.comic.title), page \(moment.bookmark.page + 1)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Remove from Highlights") { remove(moment) }
    }

    private func remove(_ moment: FavoriteMoment) {
        moments.removeAll { $0.id == moment.id }
        Task.detached(priority: .utility) {
            DatabaseManager.shared.setBookmarkFavorite(
                comicId: moment.comic.id, page: moment.bookmark.page, isFavorite: false)
        }
    }

    private func load() async {
        isLoading = true
        moments = await Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.favoriteMoments()
        }.value
        isLoading = false
    }
}

/// Renders a specific page of a comic as a thumbnail (as opposed to `MiniComicCard`, which always
/// shows the cover) -- used to make a favorite moment recognizable in a browsing list without
/// opening the reader first.
private struct PageThumbnail: View {
    let comic: Comic
    let page: Int
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Design.cardBg)
            if let image {
                Image(platformImage: image)
                    .resizable().aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(comic.id):\(page)") {
            PageCache.shared.load(comic: comic, page: page) { image = $0 }
        }
    }
}
