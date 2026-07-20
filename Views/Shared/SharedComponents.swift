import SwiftUI

// MARK: - Shimmer placeholder card

struct ShimmerCard: View {
    var width: CGFloat = 140
    var height: CGFloat = 200
    @State private var animating = false

    var body: some View {
        RoundedRectangle(cornerRadius: Design.cardCorner)
            .fill(
                LinearGradient(
                    colors: [Design.cardBg, Design.cardBg.opacity(0.5), Design.cardBg],
                    startPoint: animating ? .topLeading : .bottomTrailing,
                    endPoint:   animating ? .bottomTrailing : .topLeading
                )
            )
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
    }
}

// MARK: - Mini comic card (thumbnail + fallback)

struct MiniComicCard: View {
    let comic: Comic
    @State private var thumbnail: PlatformImage?

    var body: some View {
        Group {
            if let img = thumbnail {
                Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.1)
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
        }
        .comicCardStyle()
        .task { ThumbnailCache.shared.thumbnail(for: comic) { thumbnail = $0 } }
    }
}

// MARK: - Cover picker (choose an existing comic's cover)

// Reusable "Choose Existing Cover…" sheet — browsing and picking a cover from a comic
// already in the library, rather than requiring an external image file, which was
// previously the only option for series/run/group custom covers.
struct CoverPickerSheet: View {
    let title: String
    let onPick: (Comic) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [Comic] = []
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 130), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
            }
            .padding(20)

            TextField("Search your library…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.bottom, 14)
                .onChange(of: searchText) { _, _ in load() }

            Divider()

            if isLoading && results.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No comics found").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(results) { comic in
                            VStack(alignment: .leading, spacing: 4) {
                                MiniComicCard(comic: comic).frame(width: 108, height: 156)
                                Text(comic.title).font(.caption2).lineLimit(2).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(comic); dismiss() }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 560, height: 520)
        .task { load() }
    }

    private func load() {
        isLoading = true
        let query = searchText
        Task.detached(priority: .userInitiated) {
            let comics = DatabaseManager.shared.allComics(search: query.isEmpty ? nil : query, sortOrder: .title)
            let limited = Array(comics.prefix(300))
            await MainActor.run { results = limited; isLoading = false }
        }
    }
}
