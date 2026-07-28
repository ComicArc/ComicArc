import Testing
import Foundation
@testable import ComicArc

final class DiaryEntryTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "DiaryEntryTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    private func insertComic(title: String) throws -> Int64 {
        try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: title)
    }

    @Test func setRatingCreatesOneDiaryEntry() throws {
        let id = try insertComic(title: "Batman #1")
        db.setRating(id, rating: 4)

        let entries = db.diaryEntries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.rating == 4)
        #expect(entry.isReread == false)
    }

    @Test func reRatingSameDayCollapsesIntoSingleEntry() throws {
        let id = try insertComic(title: "Batman #1")
        db.setRating(id, rating: 3)
        db.setRating(id, rating: 5)

        let entries = db.diaryEntries()
        #expect(entries.count == 1, "same-day rating edits should update the existing entry, not add a new one")
        #expect(try #require(entries.first).rating == 5)
    }

    @Test func settingReviewAlsoLogsDiaryEntry() throws {
        let id = try insertComic(title: "Batman #1")
        db.setRating(id, rating: 4)
        db.setComicReview(id, review: "A genuine classic.")

        let entries = db.diaryEntries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.review == "A genuine classic.")
        #expect(entry.rating == 4)
    }

    @Test func unratedComicNeverAppearsInDiary() throws {
        _ = try insertComic(title: "Batman #1")
        #expect(db.diaryEntries().isEmpty)
    }

    @Test func zeroRatingDoesNotLogDiaryEntry() throws {
        let id = try insertComic(title: "Batman #1")
        db.setRating(id, rating: 0)
        #expect(db.diaryEntries().isEmpty)
    }

    @Test func multipleComicsOrderedMostRecentFirst() throws {
        let first  = try insertComic(title: "Batman #1")
        let second = try insertComic(title: "Batman #2")
        db.setRating(first, rating: 3)
        db.setRating(second, rating: 5)

        let entries = db.diaryEntries()
        #expect(entries.count == 2)
        #expect(entries.first?.comic.id == second, "most recently logged entry should be first")
    }

    @Test("Simulates a reread by directly backdating the first entry, then rating again -- exercises the exact \"not same day\" branch _logDiaryEntryUnlocked takes for a real reread")
    func distinctDiaryEntryIdsEvenForSameComicAcrossDays() throws {
        let id = try insertComic(title: "Batman #1")
        db.setRating(id, rating: 3)
        #expect(db.exec("UPDATE diary_entries SET logged_at = datetime('now', '-30 days') WHERE comic_id = \(id)"))
        db.setRating(id, rating: 5)

        let entries = db.diaryEntries()
        #expect(entries.count == 2, "a rating on a genuinely different day should create a new entry")
        #expect(Set(entries.map(\.id)).count == 2, "each diary entry must have a unique id")
        #expect(entries.contains { $0.isReread }, "the second entry should be marked as a reread")
        #expect(entries.allSatisfy { $0.isReread } == false, "the original entry should not retroactively become a reread")
    }

    @Test func deleteDiaryEntryRemovesOnlyThatEntry() throws {
        let first  = try insertComic(title: "Batman #1")
        let second = try insertComic(title: "Batman #2")
        db.setRating(first, rating: 3)
        db.setRating(second, rating: 5)
        let toDelete = try #require(db.diaryEntries().first { $0.comic.id == first }).id

        db.deleteDiaryEntry(id: toDelete)

        let remaining = db.diaryEntries()
        #expect(remaining.count == 1)
        #expect(remaining[0].comic.id == second)
    }

    @Test("Backup restore must replay each original entry verbatim -- unlike setRating (which collapses same-day edits into the existing row), restoring two entries logged on the same original day must produce two distinct rows, each keeping its own historical logged_at rather than being stamped with the current time")
    func restoreDiaryEntryBypassesSameDayCollapseAndPreservesTimestamp() throws {
        let id = try insertComic(title: "Batman #1")
        db.restoreDiaryEntry(comicId: id, rating: 3, review: "First read", isReread: false,
                             loggedAt: "2020-01-01 10:00:00")
        db.restoreDiaryEntry(comicId: id, rating: 5, review: "Reread, even better", isReread: true,
                             loggedAt: "2020-01-01 11:00:00")

        let entries = db.diaryEntries()
        #expect(entries.count == 2, "restoring backdated entries must not collapse them even when logged the same historical day")
        #expect(Set(entries.map(\.loggedAt)) == ["2020-01-01 10:00:00", "2020-01-01 11:00:00"],
                "restored entries must keep their original timestamps, not the current time")
        #expect(entries.contains { $0.isReread && $0.rating == 5 })
        #expect(entries.contains { !$0.isReread && $0.rating == 3 })
    }

    @Test func allReadingOrderOverridesReturnsFilePathPositionAndReason() throws {
        let id = try insertComic(title: "Batman Annual #1")
        db.setReadingOrderOverride(comicId: id, position: 42, reason: "Placed manually by the user")

        let overrides = db.allReadingOrderOverrides()
        #expect(overrides.count == 1)
        #expect(overrides[0].position == 42)
        #expect(overrides[0].reason == "Placed manually by the user")
        #expect(overrides[0].filePath.hasSuffix(".cbz"))
    }
}
