import Foundation

@MainActor
final class ReadingSessionService {
    static let shared = ReadingSessionService()
    private init() {}

    func updateProgress(comic: Comic, page: Int) {
        LibraryViewModel.shared.updateProgress(comic: comic, page: page)
    }

    func logSession(comicId: Int64, from startPage: Int, to endPage: Int) {
        DatabaseManager.shared.logReadingSession(
            comicId: comicId,
            pageStart: min(startPage, endPage),
            pageEnd: max(startPage, endPage)
        )
    }

    func bookmarks(for comicId: Int64) -> [Bookmark] {
        DatabaseManager.shared.bookmarks(comicId: comicId)
    }

    @discardableResult
    func toggleBookmark(comicId: Int64, page: Int) -> Bool {
        DatabaseManager.shared.toggleBookmark(comicId: comicId, page: page)
    }
}
