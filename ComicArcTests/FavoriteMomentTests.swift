import Testing
import Foundation
@testable import ComicArc

final class FavoriteMomentTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "FavoriteMomentTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    private func insertComic(title: String) throws -> Int64 {
        try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: title)
    }

    @Test func settingFavoriteOnAnUnbookmarkedPageCreatesTheBookmark() throws {
        let id = try insertComic(title: "Batman #1")
        #expect(db.isBookmarked(comicId: id, page: 5) == false)

        db.setBookmarkFavorite(comicId: id, page: 5, isFavorite: true)

        #expect(db.isBookmarked(comicId: id, page: 5))
        let bookmark = db.bookmarks(comicId: id).first
        #expect(bookmark?.isFavorite == true)
    }

    @Test func favoritingAnExistingBookmarkPreservesItsLabel() throws {
        let id = try insertComic(title: "Batman #1")
        db.toggleBookmark(comicId: id, page: 5)
        db.setBookmarkLabel(comicId: id, page: 5, label: "Joker's first appearance")

        db.setBookmarkFavorite(comicId: id, page: 5, isFavorite: true)

        let bookmark = db.bookmarks(comicId: id).first
        #expect(bookmark?.label == "Joker's first appearance")
        #expect(bookmark?.isFavorite == true)
    }

    @Test func favoriteMomentsOnlyIncludesFlaggedBookmarks() throws {
        let id = try insertComic(title: "Batman #1")
        db.toggleBookmark(comicId: id, page: 3)
        db.toggleBookmark(comicId: id, page: 7)
        db.setBookmarkFavorite(comicId: id, page: 7, isFavorite: true)

        let moments = db.favoriteMoments()
        #expect(moments.count == 1)
        #expect(moments.first?.bookmark.page == 7)
    }

    @Test func unfavoritingRemovesItFromFavoriteMomentsButKeepsTheBookmark() throws {
        let id = try insertComic(title: "Batman #1")
        db.setBookmarkFavorite(comicId: id, page: 5, isFavorite: true)
        #expect(db.favoriteMoments().count == 1)

        db.setBookmarkFavorite(comicId: id, page: 5, isFavorite: false)

        #expect(db.favoriteMoments().isEmpty)
        #expect(db.isBookmarked(comicId: id, page: 5), "un-favoriting should not delete the underlying bookmark")
    }

    @Test func favoriteMomentsAcrossMultipleComicsResolvesEachComic() throws {
        let first  = try insertComic(title: "Batman #1")
        let second = try insertComic(title: "Batman #2")
        db.setBookmarkFavorite(comicId: first, page: 2, isFavorite: true)
        db.setBookmarkFavorite(comicId: second, page: 9, isFavorite: true)

        let moments = db.favoriteMoments()
        #expect(moments.count == 2)
        #expect(Set(moments.map(\.comic.id)) == [first, second])
    }
}
