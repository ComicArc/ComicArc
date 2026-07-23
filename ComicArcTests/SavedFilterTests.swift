import XCTest
@testable import ComicArc

final class SavedFilterTests: XCTestCase {
    private var db: DatabaseManager!
    private var tempPath: String!

    override func setUp() {
        super.setUp()
        tempPath = NSTemporaryDirectory() + "SavedFilterTests-\(UUID().uuidString).sqlite"
        db = DatabaseManager(dbPath: tempPath)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: tempPath)
        super.tearDown()
    }

    @discardableResult
    private func insertComic(title: String, year: Int? = nil, pageCount: Int = 20) -> Int64 {
        db.batchInsert([DatabaseManager.ComicInsert(
            title: title, filePath: "/tmp/\(UUID().uuidString).cbz", publisher: "DC",
            character: nil, series: "Batman", issueNumber: "1", pageCount: pageCount,
            writer: nil, penciller: nil, year: year, storyArc: nil, languageIso: nil, fileHash: nil
        )])
        return db.allComics(series: "Batman", sortOrder: .manual).first { $0.title == title }!.id
    }

    // MARK: - CRUD

    func test_createSavedFilter_appearsInSavedFilters() {
        let id = db.createSavedFilter(name: "Unread Batman", publisher: "DC", tag: nil, writer: nil,
                                       readStatus: "unread", yearMin: nil, yearMax: nil, sortOrder: nil)
        let filters = db.savedFilters()
        XCTAssertEqual(filters.count, 1)
        XCTAssertEqual(filters[0].id, id)
        XCTAssertEqual(filters[0].name, "Unread Batman")
        XCTAssertEqual(filters[0].publisher, "DC")
        XCTAssertEqual(filters[0].readStatus, "unread")
    }

    func test_deleteSavedFilter_removesIt() {
        let id = db.createSavedFilter(name: "Temp", publisher: nil, tag: nil, writer: nil,
                                       readStatus: nil, yearMin: nil, yearMax: nil, sortOrder: nil)
        db.deleteSavedFilter(id)
        XCTAssertTrue(db.savedFilters().isEmpty)
    }

    // MARK: - readStatus filtering boundaries

    func test_readStatus_unread_excludesAnyProgress() {
        insertComic(title: "Unread", pageCount: 20)
        let started = insertComic(title: "Started", pageCount: 20)
        db.updateProgress(comicId: started, page: 5)

        let results = db.allComics(readStatus: "unread").map(\.title)
        XCTAssertEqual(results, ["Unread"])
    }

    func test_readStatus_finished_requiresLastPage() {
        let finished = insertComic(title: "Finished", pageCount: 20)
        let almostDone = insertComic(title: "AlmostDone", pageCount: 20)
        db.updateProgress(comicId: finished, page: 19)   // pageCount-1, matches isFinished's own boundary
        db.updateProgress(comicId: almostDone, page: 18)

        let results = db.allComics(readStatus: "finished").map(\.title)
        XCTAssertEqual(results, ["Finished"])
    }

    func test_readStatus_inProgress_excludesUnreadAndFinished() {
        insertComic(title: "Unread", pageCount: 20)
        let started  = insertComic(title: "Started", pageCount: 20)
        let finished = insertComic(title: "Finished", pageCount: 20)
        db.updateProgress(comicId: started, page: 5)
        db.updateProgress(comicId: finished, page: 19)

        let results = db.allComics(readStatus: "in_progress").map(\.title)
        XCTAssertEqual(results, ["Started"])
    }

    // MARK: - year range filtering

    func test_yearRange_inclusiveBounds() {
        insertComic(title: "Before", year: 1999)
        insertComic(title: "Start", year: 2000)
        insertComic(title: "Middle", year: 2010)
        insertComic(title: "End", year: 2020)
        insertComic(title: "After", year: 2021)

        let results = Set(db.allComics(yearMin: 2000, yearMax: 2020).map(\.title))
        XCTAssertEqual(results, ["Start", "Middle", "End"])
    }

    func test_yearRange_excludesNullYear() {
        insertComic(title: "NoYear", year: nil)
        insertComic(title: "HasYear", year: 2010)

        let results = db.allComics(yearMin: 2000, yearMax: 2020).map(\.title)
        XCTAssertEqual(results, ["HasYear"], "a comic with no year must not match a year-range filter")
    }

    // MARK: - end-to-end: a saved filter's stored criteria actually narrows results

    func test_combinedFilter_publisherAndReadStatus() {
        insertComic(title: "DC Unread")
        db.batchInsert([DatabaseManager.ComicInsert(
            title: "Marvel Unread", filePath: "/tmp/\(UUID().uuidString).cbz", publisher: "Marvel",
            character: nil, series: "Avengers", issueNumber: "1", pageCount: 20,
            writer: nil, penciller: nil, year: nil, storyArc: nil, languageIso: nil, fileHash: nil
        )])
        let dcStarted = insertComic(title: "DC Started")
        db.updateProgress(comicId: dcStarted, page: 5)

        let results = db.allComics(publisher: "DC", readStatus: "unread").map(\.title)
        XCTAssertEqual(results, ["DC Unread"], "publisher and readStatus conditions must combine with AND")
    }
}
