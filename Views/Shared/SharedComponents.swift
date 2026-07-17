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
