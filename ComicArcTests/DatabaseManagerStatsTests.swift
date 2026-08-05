import Testing
import Foundation
@testable import ComicArc

/// Covers `currentReadingStreak()` (new: backs the sidebar's ambient streak indicator) --
/// `computeStreak(dates:)` itself already has indirect coverage via `YearInReviewTests`, so this
/// focuses on the DB-querying wrapper: does it feed `computeStreak` the right rows.
final class DatabaseManagerStatsTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "DatabaseManagerStatsTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    /// Computed via SQLite's own `datetime('now', ...)`, not Swift's `Calendar` -- `last_read` is
    /// always written that way in production (see `updateProgress`), and `computeStreak` parses
    /// it back as a UTC string before reasoning about it in the local calendar. Hand-computing an
    /// equivalent Swift `Date` and reformatting it as UTC very easily lands on the wrong SQL day
    /// whenever the sandbox's local timezone isn't UTC -- letting SQLite do both the writing and
    /// the "N days ago" arithmetic keeps the test consistent with what the app itself produces.
    private func logRead(comicId: Int64, daysAgo: Int) throws {
        #expect(db.exec("""
            INSERT INTO reading_progress (comic_id, current_page, last_read)
            VALUES (\(comicId), 1, datetime('now', '-\(daysAgo) days'))
            """))
    }

    @Test func currentReadingStreakIsZeroWithNoReadingActivity() {
        #expect(db.currentReadingStreak() == 0)
    }

    @Test func currentReadingStreakIsOneWhenOnlyReadToday() throws {
        let id = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        try logRead(comicId: id, daysAgo: 0)

        #expect(db.currentReadingStreak() == 1)
    }

    @Test func currentReadingStreakCountsConsecutiveDaysBackFromToday() throws {
        let a = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        let b = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "2", title: "Batman #2")
        let c = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "3", title: "Batman #3")
        try logRead(comicId: a, daysAgo: 0)
        try logRead(comicId: b, daysAgo: 1)
        try logRead(comicId: c, daysAgo: 2)

        #expect(db.currentReadingStreak() == 3)
    }

    @Test func currentReadingStreakStillCountsWhenTodayHasNoReadYetButYesterdayDoes() throws {
        let id = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        try logRead(comicId: id, daysAgo: 1)

        #expect(db.currentReadingStreak() == 1, "a streak started yesterday shouldn't reset to 0 before today ends")
    }

    @Test func currentReadingStreakBreaksOnAGap() throws {
        let recent = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        let old = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "2", title: "Batman #2")
        try logRead(comicId: recent, daysAgo: 0)
        try logRead(comicId: old, daysAgo: 3) // gap at day 1/2 -- must not count past it

        #expect(db.currentReadingStreak() == 1)
    }

    @Test func currentReadingStreakIsZeroIfLastReadWasNeitherTodayNorYesterday() throws {
        let id = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        try logRead(comicId: id, daysAgo: 5)

        #expect(db.currentReadingStreak() == 0)
    }
}
