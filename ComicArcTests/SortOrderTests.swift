import XCTest
@testable import ComicArc

final class SortOrderTests: XCTestCase {
    private var db: DatabaseManager!
    private var tempPath: String!

    override func setUp() {
        super.setUp()
        tempPath = NSTemporaryDirectory() + "SortOrderTests-\(UUID().uuidString).sqlite"
        db = DatabaseManager(dbPath: tempPath)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: tempPath)
        super.tearDown()
    }

    private func insertComic(title: String, year: Int? = nil, storyArc: String? = nil,
                              pageCount: Int = 20, writer: String? = nil) {
        db.batchInsert([DatabaseManager.ComicInsert(
            title: title, filePath: "/tmp/\(UUID().uuidString).cbz", publisher: "DC",
            character: nil, series: "Batman", issueNumber: "1", pageCount: pageCount,
            writer: writer, penciller: nil, year: year, storyArc: storyArc, languageIso: nil, fileHash: nil
        )])
    }

    func test_sortByYear_descendingWithNullsLast() {
        insertComic(title: "Old", year: 1990)
        insertComic(title: "New", year: 2020)
        insertComic(title: "NoYear", year: nil)

        let titles = db.allComics(sortOrder: .year).map(\.title)
        XCTAssertEqual(titles, ["New", "Old", "NoYear"])
    }

    func test_sortByPageCount_descending() {
        insertComic(title: "Short", pageCount: 20)
        insertComic(title: "Long", pageCount: 100)

        let titles = db.allComics(sortOrder: .pageCount).map(\.title)
        XCTAssertEqual(titles, ["Long", "Short"])
    }

    func test_sortByStoryArc_alphabeticalWithNullsFirst() {
        insertComic(title: "Zero Year", storyArc: "Zero Year")
        insertComic(title: "No Arc", storyArc: nil)
        insertComic(title: "Court of Owls", storyArc: "Court of Owls")

        let titles = db.allComics(sortOrder: .storyArc).map(\.title)
        XCTAssertEqual(titles, ["No Arc", "Court of Owls", "Zero Year"])
    }

    func test_sortByWriter_alphabetical() {
        insertComic(title: "Snyder Issue", writer: "Scott Snyder")
        insertComic(title: "No Writer", writer: nil)
        insertComic(title: "King Issue", writer: "Tom King")

        let titles = db.allComics(sortOrder: .writer).map(\.title)
        XCTAssertEqual(titles, ["No Writer", "Snyder Issue", "King Issue"])
    }

    func test_sortByDateRead_mostRecentFirstUnreadLast() {
        insertComic(title: "ReadOnce")
        insertComic(title: "Unread")

        let comics = db.allComics(sortOrder: .manual)
        let readOnce = comics.first { $0.title == "ReadOnce" }!
        db.updateProgress(comicId: readOnce.id, page: 1)

        let titles = db.allComics(sortOrder: .dateRead).map(\.title)
        XCTAssertEqual(titles, ["ReadOnce", "Unread"], "a real last_read timestamp must sort ahead of an unread comic's empty COALESCE fallback in DESC order")
    }
}
