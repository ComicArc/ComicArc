import SwiftUI

/// A celebratory recap shown the moment every issue currently in the library for one series has
/// been read -- "complete" is deliberately library-relative (zero unread issues among what's
/// actually on disk right now), not a claim about whether the real-world series has ended, since
/// nothing in the schema tracks that and most series a user reads are ongoing anyway.
struct SeriesCompleteView: View {
    let publisher: String
    let series: String

    @Environment(\.dismiss) private var dismiss

    @State private var comics: [Comic] = []
    @State private var isLoading = true
    @State private var accentColor: Color?
    @State private var shareCardURL: URL?

    private var averageRating: Double? {
        let rated = comics.filter { $0.rating > 0 }
        guard !rated.isEmpty else { return nil }
        return Double(rated.reduce(0) { $0 + $1.rating }) / Double(rated.count)
    }

    private var topRated: Comic? {
        comics.filter { $0.rating > 0 }.max { $0.rating < $1.rating }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        heroCard

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            RecapStatTile(label: "ISSUES READ", value: "\(comics.count)", icon: "book.closed.fill",
                                          tint: accentColor ?? Design.brandGold)
                            RecapStatTile(label: "AVG RATING", value: averageRating.map { String(format: "%.1f★", $0) } ?? "—",
                                          icon: "star.fill", tint: accentColor ?? Design.brandGold)
                        }

                        if let topRated {
                            RecapHighlightRow(icon: "trophy.fill", label: "Highest Rated", value: topRated.title,
                                               detail: "\(topRated.rating)★", tint: accentColor ?? Design.brandGold)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(width: 460, height: 520)
        .background(Design.appBackground)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Series Complete").font(.title3.bold())
                Text(series).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let shareCardURL {
                ShareLink(item: shareCardURL, preview: SharePreview("\(series) — Complete")) {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Share as Image")
                .padding(.trailing, 4)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.escape)
        }
        .padding(20)
    }

    private var heroCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(accentColor ?? Design.brandGold)
            Text(series)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
            Text("You've read every issue in your library")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background((accentColor ?? Design.brandGold).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Design.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: Design.cardCorner).stroke(Design.borderColor, lineWidth: 1))
    }

    private func load() async {
        let pub = publisher, ser = series
        let loaded = await Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.allComics(publisher: pub, series: ser, sortOrder: .manual)
        }.value
        comics = loaded
        isLoading = false

        guard let first = loaded.first else { return }

        // Independent of each other -- run concurrently rather than making the share card wait
        // through both one after another.
        async let accentColorResult: Color? = withCheckedContinuation { continuation in
            ThumbnailCache.shared.accentColor(for: first) { continuation.resume(returning: $0) }
        }
        async let imagesResult: [PlatformImage] = Task.detached(priority: .utility) {
            loaded.prefix(6).compactMap { ThumbnailCache.shared.thumbnailSync(for: $0) }
        }.value

        let (resolvedAccentColor, images) = await (accentColorResult, imagesResult)
        accentColor = resolvedAccentColor

        let card = ShareCardView(
            title: series,
            subtitle: "\(loaded.count) issue\(loaded.count == 1 ? "" : "s") — series complete",
            covers: images,
            stats: averageRating.map { [("Avg Rating", String(format: "%.1f★", $0))] } ?? []
        )
        shareCardURL = ShareCardRenderer.renderToTempPNG(card, filename: "SeriesComplete-\(series).png")
    }
}
