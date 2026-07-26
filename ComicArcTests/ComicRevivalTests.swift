import Testing
import Foundation
@testable import ComicArc

final class ComicRevivalTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "ComicRevivalTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    private func insert(title: String, path: String) throws {
        try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: title, filePath: path)
    }

    @Test func softDeletedComicRevivesOnRescanAtSamePath() throws {
        let path = "/tmp/\(UUID().uuidString).cbz"
        try insert(title: "Batman #1", path: path)
        let original = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)
        let originalId = original.id

        // Rate it and mark it a favorite, so we can confirm this survives the revival --
        // it's the same row, not a delete-and-recreate.
        db.setRating(originalId, rating: 5)
        db.setFavorite(originalId, true)

        db.softDelete([originalId])
        #expect(db.allComics(series: "Batman", sortOrder: .manual).isEmpty,
                "soft-deleted comic must not appear in the library")

        // Simulate a rescan finding the file again at the exact same path.
        try insert(title: "Batman #1", path: path)

        let revived = db.allComics(series: "Batman", sortOrder: .manual)
        #expect(revived.count == 1, "the comic must come back -- this is the core of the bug: INSERT OR IGNORE could never revive a soft-deleted row due to the UNIQUE(file_path) conflict")
        #expect(revived[0].id == originalId, "reviving the SAME row (not creating a new one) is what keeps rating/favorite/tags/list-membership intact")
        #expect(revived[0].rating == 5, "user data on the row must survive a revival")
        #expect(revived[0].isFavorite)
    }

    @Test func softDeletedComicIdFindsOnlyDeletedRows() throws {
        let path = "/tmp/\(UUID().uuidString).cbz"
        try insert(title: "Batman #1", path: path)
        let id = try #require(db.allComics(series: "Batman", sortOrder: .manual).first).id

        #expect(db.softDeletedComicId(atPath: path) == nil, "an active (non-deleted) comic must not match")

        db.softDelete([id])
        #expect(db.softDeletedComicId(atPath: path) == id)
    }

    @Test func revivalRefreshesMetadataFromNewScan() throws {
        let path = "/tmp/\(UUID().uuidString).cbz"
        try insert(title: "Batman #1", path: path)
        let id = try #require(db.allComics(series: "Batman", sortOrder: .manual).first).id
        db.softDelete([id])

        // Revive with different metadata, simulating the file having been re-tagged/renamed
        // on disk while the row was soft-deleted.
        db.batchInsert([DatabaseManager.ComicInsert(
            title: "Batman #1 (2016)", filePath: path, publisher: "DC",
            character: nil, series: "Batman", issueNumber: "1", pageCount: 22,
            writer: "Tom King", penciller: nil, year: 2016, storyArc: nil, languageIso: nil, fileHash: nil
        )])

        let revived = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)
        #expect(revived.id == id)
        #expect(revived.title == "Batman #1 (2016)")
        #expect(revived.pageCount == 22)
        #expect(revived.writer == "Tom King")
    }
}
