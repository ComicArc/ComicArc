import Testing
import Foundation
@testable import ComicArc

final class SortOrderTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "SortOrderTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    private func insertComic(title: String, year: Int? = nil, storyArc: String? = nil,
                              pageCount: Int = 20, writer: String? = nil) throws {
        try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: title,
                             pageCount: pageCount, writer: writer, year: year, storyArc: storyArc)
    }

    @Test func sortByYearDescendingWithNullsLast() throws {
        try insertComic(title: "Old", year: 1990)
        try insertComic(title: "New", year: 2020)
        try insertComic(title: "NoYear", year: nil)

        let titles = db.allComics(sortOrder: .year).map(\.title)
        #expect(titles == ["New", "Old", "NoYear"])
    }

    @Test func sortByPageCountDescending() throws {
        try insertComic(title: "Short", pageCount: 20)
        try insertComic(title: "Long", pageCount: 100)

        let titles = db.allComics(sortOrder: .pageCount).map(\.title)
        #expect(titles == ["Long", "Short"])
    }

    @Test func sortByStoryArcAlphabeticalWithNullsFirst() throws {
        try insertComic(title: "Zero Year", storyArc: "Zero Year")
        try insertComic(title: "No Arc", storyArc: nil)
        try insertComic(title: "Court of Owls", storyArc: "Court of Owls")

        let titles = db.allComics(sortOrder: .storyArc).map(\.title)
        #expect(titles == ["No Arc", "Court of Owls", "Zero Year"])
    }

    @Test func sortByWriterAlphabetical() throws {
        try insertComic(title: "Snyder Issue", writer: "Scott Snyder")
        try insertComic(title: "No Writer", writer: nil)
        try insertComic(title: "King Issue", writer: "Tom King")

        let titles = db.allComics(sortOrder: .writer).map(\.title)
        #expect(titles == ["No Writer", "Snyder Issue", "King Issue"])
    }

    @Test func sortByDateReadMostRecentFirstUnreadLast() throws {
        try insertComic(title: "ReadOnce")
        try insertComic(title: "Unread")

        let comics = db.allComics(sortOrder: .manual)
        let readOnce = try #require(comics.first { $0.title == "ReadOnce" })
        db.updateProgress(comicId: readOnce.id, page: 1)

        let titles = db.allComics(sortOrder: .dateRead).map(\.title)
        #expect(titles == ["ReadOnce", "Unread"], "a real last_read timestamp must sort ahead of an unread comic's empty COALESCE fallback in DESC order")
    }
}
