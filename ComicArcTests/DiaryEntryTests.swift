import XCTest
@testable import ComicArc

final class DiaryEntryTests: XCTestCase {
    private var db: DatabaseManager!
    private var tempPath: String!

    override func setUp() {
        super.setUp()
        tempPath = NSTemporaryDirectory() + "DiaryEntryTests-\(UUID().uuidString).sqlite"
        db = DatabaseManager(dbPath: tempPath)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: tempPath)
        super.tearDown()
    }

    private func insertComic(title: String) -> Int64 {
        db.batchInsert([DatabaseManager.ComicInsert(
            title: title, filePath: "/tmp/\(UUID().uuidString).cbz", publisher: "DC",
            character: nil, series: "Batman", issueNumber: "1", pageCount: 20,
            writer: nil, penciller: nil, year: nil, storyArc: nil, languageIso: nil, fileHash: nil
        )])
        return db.allComics(series: "Batman", sortOrder: .manual).first { $0.title == title }!.id
    }

    func test_setRating_createsOneDiaryEntry() {
        let id = insertComic(title: "Batman #1")
        db.setRating(id, rating: 4)

        let entries = db.diaryEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].rating, 4)
        XCTAssertFalse(entries[0].isReread)
    }

    func test_reRatingSameDay_collapsesIntoSingleEntry() {
        let id = insertComic(title: "Batman #1")
        db.setRating(id, rating: 3)
        db.setRating(id, rating: 5)

        let entries = db.diaryEntries()
        XCTAssertEqual(entries.count, 1, "same-day rating edits should update the existing entry, not add a new one")
        XCTAssertEqual(entries[0].rating, 5)
    }

    func test_settingReview_alsoLogsDiaryEntry() {
        let id = insertComic(title: "Batman #1")
        db.setRating(id, rating: 4)
        db.setComicReview(id, review: "A genuine classic.")

        let entries = db.diaryEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].review, "A genuine classic.")
        XCTAssertEqual(entries[0].rating, 4)
    }

    func test_unratedComic_neverAppearsInDiary() {
        _ = insertComic(title: "Batman #1")
        XCTAssertTrue(db.diaryEntries().isEmpty)
    }

    func test_zeroRating_doesNotLogDiaryEntry() {
        let id = insertComic(title: "Batman #1")
        db.setRating(id, rating: 0)
        XCTAssertTrue(db.diaryEntries().isEmpty)
    }

    func test_multipleComics_orderedMostRecentFirst() {
        let first  = insertComic(title: "Batman #1")
        let second = insertComic(title: "Batman #2")
        db.setRating(first, rating: 3)
        db.setRating(second, rating: 5)

        let entries = db.diaryEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.comic.id, second, "most recently logged entry should be first")
    }

    func test_distinctDiaryEntryIds_evenForSameComicAcrossDays() {
        // Simulates a reread by directly backdating the first entry, then rating again --
        // exercises the exact "not same day" branch _logDiaryEntryUnlocked takes for a real reread.
        let id = insertComic(title: "Batman #1")
        db.setRating(id, rating: 3)
        XCTAssertTrue(db.exec("UPDATE diary_entries SET logged_at = datetime('now', '-30 days') WHERE comic_id = \(id)"))
        db.setRating(id, rating: 5)

        let entries = db.diaryEntries()
        XCTAssertEqual(entries.count, 2, "a rating on a genuinely different day should create a new entry")
        XCTAssertEqual(Set(entries.map(\.id)).count, 2, "each diary entry must have a unique id")
        XCTAssertTrue(entries.contains { $0.isReread }, "the second entry should be marked as a reread")
        XCTAssertFalse(entries.allSatisfy { $0.isReread }, "the original entry should not retroactively become a reread")
    }
}
