import Foundation

/// Resolves the previous/next issue relative to a comic -- scoped to a run's ordered items when
/// opened from a run, series order otherwise. Both platform readers previously duplicated this
/// exact lookup verbatim; it's genuinely identical logic regardless of platform, so it lives once
/// here and `ReaderSession` calls it once, not per platform.
enum NextIssueResolver {
    struct Result { let next: Comic?; let previous: Comic? }

    static func resolve(for comic: Comic, runId: Int64?) -> Result {
        if let runId {
            let items = DatabaseManager.shared.runItems(runId: runId)
            guard let idx = items.firstIndex(where: { $0.comic.id == comic.id }) else {
                return Result(next: nil, previous: nil)
            }
            let next = idx + 1 < items.count ? items[idx + 1].comic : nil
            let previous = idx > 0 ? items[idx - 1].comic : nil
            return Result(next: next, previous: previous)
        }
        return Result(
            next: DatabaseManager.shared.nextComic(after: comic),
            previous: DatabaseManager.shared.previousComic(before: comic)
        )
    }

    /// Warms just the next issue's cover -- cheap and format-agnostic, so it's always worth doing
    /// speculatively. Prefetching actual *pages* of the next issue is `ReaderSession`'s job, not
    /// this resolver's: it requires opening a `ComicDocument`, which for CBR means a real
    /// subprocess extraction -- `ReaderSession` decides whether that's worth doing speculatively
    /// (see `loadAdjacentIssues()`), since it already owns the `PageStore` interaction this would
    /// otherwise duplicate.
    static func prefetchCover(for comic: Comic?) {
        guard let comic else { return }
        ThumbnailCache.shared.thumbnail(for: comic) { _ in }
    }
}
