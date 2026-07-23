import XCTest
@testable import ComicArc

final class ComicRevivalTests: XCTestCase {
    private var db: DatabaseManager!
    private var tempPath: String!

    override func setUp() {
        super.setUp()
        tempPath = NSTemporaryDirectory() + "ComicRevivalTests-\(UUID().uuidString).sqlite"
        db = DatabaseManager(dbPath: tempPath)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: tempPath)
        super.tearDown()
    }

    private func insert(title: String, path: String) {
        db.batchInsert([DatabaseManager.ComicInsert(
            title: title, filePath: path, publisher: "DC",
            character: nil, series: "Batman", issueNumber: "1", pageCount: 20,
            writer: nil, penciller: nil, year: nil, storyArc: nil, languageIso: nil, fileHash: nil
        )])
    }

    func test_softDeletedComic_revivesOnRescanAtSamePath() {
        let path = "/tmp/\(UUID().uuidString).cbz"
        insert(title: "Batman #1", path: path)
        let original = db.allComics(series: "Batman", sortOrder: .manual).first!
        let originalId = original.id

        // Rate it and mark it a favorite, so we can confirm this survives the revival --
        // it's the same row, not a delete-and-recreate.
        db.setRating(originalId, rating: 5)
        db.setFavorite(originalId, true)

        db.softDelete([originalId])
        XCTAssertTrue(db.allComics(series: "Batman", sortOrder: .manual).isEmpty,
                      "soft-deleted comic must not appear in the library")

        // Simulate a rescan finding the file again at the exact same path.
        insert(title: "Batman #1", path: path)

        let revived = db.allComics(series: "Batman", sortOrder: .manual)
        XCTAssertEqual(revived.count, 1, "the comic must come back -- this is the core of the bug: INSERT OR IGNORE could never revive a soft-deleted row due to the UNIQUE(file_path) conflict")
        XCTAssertEqual(revived[0].id, originalId, "reviving the SAME row (not creating a new one) is what keeps rating/favorite/tags/list-membership intact")
        XCTAssertEqual(revived[0].rating, 5, "user data on the row must survive a revival")
        XCTAssertTrue(revived[0].isFavorite)
    }

    func test_softDeletedComicId_findsOnlyDeletedRows() {
        let path = "/tmp/\(UUID().uuidString).cbz"
        insert(title: "Batman #1", path: path)
        let id = db.allComics(series: "Batman", sortOrder: .manual).first!.id

        XCTAssertNil(db.softDeletedComicId(atPath: path), "an active (non-deleted) comic must not match")

        db.softDelete([id])
        XCTAssertEqual(db.softDeletedComicId(atPath: path), id)
    }

    func test_revival_refreshesMetadataFromNewScan() {
        let path = "/tmp/\(UUID().uuidString).cbz"
        insert(title: "Batman #1", path: path)
        let id = db.allComics(series: "Batman", sortOrder: .manual).first!.id
        db.softDelete([id])

        // Revive with different metadata, simulating the file having been re-tagged/renamed
        // on disk while the row was soft-deleted.
        db.batchInsert([DatabaseManager.ComicInsert(
            title: "Batman #1 (2016)", filePath: path, publisher: "DC",
            character: nil, series: "Batman", issueNumber: "1", pageCount: 22,
            writer: "Tom King", penciller: nil, year: 2016, storyArc: nil, languageIso: nil, fileHash: nil
        )])

        let revived = db.allComics(series: "Batman", sortOrder: .manual).first!
        XCTAssertEqual(revived.id, id)
        XCTAssertEqual(revived.title, "Batman #1 (2016)")
        XCTAssertEqual(revived.pageCount, 22)
        XCTAssertEqual(revived.writer, "Tom King")
    }
}
