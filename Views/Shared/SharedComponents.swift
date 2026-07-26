import SwiftUI

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

struct CoverPickerSheet: View {
    let title: String
    let onPick: (Comic) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [Comic] = []
    @State private var isLoading = true
    @State private var searchGeneration = 0

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
        searchGeneration += 1
        let gen = searchGeneration
        // Debounced and generation-guarded: without this, every keystroke fires its own
        // detached query with no ordering guarantee, so a slow early query completing after a
        // faster later one would overwrite the correct, more recent results with stale ones.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard gen == searchGeneration else { return }
            let comics = await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.allComics(search: query.isEmpty ? nil : query, sortOrder: .title)
            }.value
            guard gen == searchGeneration else { return }
            results = Array(comics.prefix(300))
            isLoading = false
        }
    }
}
