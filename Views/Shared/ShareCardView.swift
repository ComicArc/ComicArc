import SwiftUI
import os

/// Shareable recap card: a title, up to 6 covers and a stat row.
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
                            .comicCoverStyle()
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

/// Covers from already-cached thumbnails only, so building the card stays synchronous.
enum ShareCardCovers {
    static func fromCache(_ comics: [Comic], limit: Int = 6) -> [PlatformImage] {
        comics.prefix(limit).compactMap { ThumbnailCache.shared.thumbnailFromCache(comicId: $0.id) }
    }
}

/// Renders a SwiftUI view to a temporary PNG, since a file URL works directly with `ShareLink`.
@MainActor
enum ShareCardRenderer {
    private static let logger = Logger(subsystem: "com.comicarc", category: "sharecard")

    static func renderToTempPNG<Content: View>(_ content: Content, filename: String) -> URL? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0

        let pngData: Data?
        #if os(macOS)
        if let nsImage = renderer.nsImage,
           let tiff = nsImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            pngData = rep.representation(using: .png, properties: [:])
        } else {
            pngData = nil
        }
        #else
        pngData = renderer.uiImage?.pngData()
        #endif

        guard let pngData else {
            logger.error("Failed to rasterize share card '\(filename)' to PNG data")
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            logger.error("Failed to write share card '\(filename)' to disk: \(error.localizedDescription)")
            return nil
        }
    }
}
