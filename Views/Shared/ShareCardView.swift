import SwiftUI

/// A single shareable "recap card" shape reused for Tier Lists, Reading Paths, and Year in
/// Review, rather than three bespoke layouts -- a title, up to 6 covers, and a small stat row.
struct ShareCardView: View {
    let title: String
    let subtitle: String
    let covers: [PlatformImage]
    let stats: [(label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }

            if !covers.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(covers.prefix(6).enumerated()), id: \.offset) { _, img in
                        Image(platformImage: img)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 74, height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            if !stats.isEmpty {
                HStack(spacing: 26) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.value).font(.system(size: 22, weight: .black)).foregroundStyle(.white)
                            Text(stat.label.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                                .kerning(0.5)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill").foregroundStyle(Design.brandGold)
                Text("ComicArc").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(28)
        .frame(width: 420, height: 560, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Design.brandBlue, Color.black.opacity(0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}

/// Builds the covers list for a share card from already-cached thumbnails only (no network/disk
/// wait) -- by the time a user reaches for Share on a detail view they're already looking at, its
/// item cards have almost always already warmed the cache via their own `.onAppear`. A card
/// missing a cover or two is an acceptable degradation for a feature that must stay synchronous
/// and main-thread-safe; `ThumbnailCache.thumbnailSync` blocks on a semaphore and would deadlock
/// if called from the main thread here.
enum ShareCardCovers {
    static func fromCache(_ comics: [Comic], limit: Int = 6) -> [PlatformImage] {
        comics.prefix(limit).compactMap { ThumbnailCache.shared.thumbnailFromCache(comicId: $0.id) }
    }

    static func fromCache(ids: [Int64], limit: Int = 6) -> [PlatformImage] {
        ids.prefix(limit).compactMap { ThumbnailCache.shared.thumbnailFromCache(comicId: $0) }
    }
}
