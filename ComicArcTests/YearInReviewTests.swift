import Testing
import Foundation
@testable import ComicArc

final class YearInReviewTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "YearInReviewTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    @discardableResult
    private func insertComic(series: String, publisher: String = "DC", issue: String, title: String) throws -> Int64 {
        try insertTestComic(into: db, series: series, publisher: publisher, issue: issue, title: title)
    }

    private func logSession(comicId: Int64, pages: ClosedRange<Int> = 0...19, at date: String) {
        #expect(db.exec("""
            INSERT INTO reading_history (comic_id, page_start, page_end, read_at)
            VALUES (\(comicId), \(pages.lowerBound), \(pages.upperBound), '\(date)')
            """))
    }

    @Test func availableReadingYearsReturnsDistinctYearsDescending() throws {
        let comic = try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        logSession(comicId: comic, at: "2024-03-01 10:00:00")
        logSession(comicId: comic, at: "2026-01-15 10:00:00")
        logSession(comicId: comic, at: "2025-06-01 10:00:00")

        #expect(db.availableReadingYears() == [2026, 2025, 2024])
    }

    @Test func yearInReviewCountsIssuesAndPagesForThatYearOnly() throws {
        let c1 = try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        let c2 = try insertComic(series: "Batman", issue: "2", title: "Batman #2")
        logSession(comicId: c1, pages: 0...19, at: "2026-02-01 10:00:00")
        logSession(comicId: c2, pages: 0...23, at: "2026-03-01 10:00:00")
        logSession(comicId: c1, pages: 0...19, at: "2025-02-01 10:00:00")

        let review = db.yearInReview(year: 2026)
        #expect(review.issuesRead == 2, "only the 2026 sessions should count")
        #expect(review.pagesRead == 44, "20 pages (c1) + 24 pages (c2)")
    }

    @Test func yearInReviewTopSeriesAndPublisherPickTheMostRead() throws {
        let batman1 = try insertComic(series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        let batman2 = try insertComic(series: "Batman", publisher: "DC", issue: "2", title: "Batman #2")
        let asm = try insertComic(series: "Amazing Spider-Man", publisher: "Marvel", issue: "1", title: "ASM #1")
        logSession(comicId: batman1, at: "2026-01-01 10:00:00")
        logSession(comicId: batman2, at: "2026-01-02 10:00:00")
        logSession(comicId: asm, at: "2026-01-03 10:00:00")

        let review = db.yearInReview(year: 2026)
        #expect(review.topSeries?.name == "Batman")
        #expect(review.topSeries?.count == 2)
        #expect(review.topPublisher?.name == "DC")
        #expect(review.topPublisher?.count == 2)
    }

    @Test("Longest streak must find the best run of consecutive days ANYWHERE in the year, not just one anchored to today -- distinct from the existing today/yesterday-anchored current-streak logic")
    func yearInReviewLongestStreakFindsConsecutiveDaysAnywhereInYear() throws {
        let comic = try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        // A 3-day run in February...
        logSession(comicId: comic, at: "2026-02-01 10:00:00")
        logSession(comicId: comic, at: "2026-02-02 10:00:00")
        logSession(comicId: comic, at: "2026-02-03 10:00:00")
        // ...and a longer 5-day run in June, which should win.
        logSession(comicId: comic, at: "2026-06-01 10:00:00")
        logSession(comicId: comic, at: "2026-06-02 10:00:00")
        logSession(comicId: comic, at: "2026-06-03 10:00:00")
        logSession(comicId: comic, at: "2026-06-04 10:00:00")
        logSession(comicId: comic, at: "2026-06-05 10:00:00")
        // An isolated day, no streak.
        logSession(comicId: comic, at: "2026-09-01 10:00:00")

        #expect(db.yearInReview(year: 2026).longestStreakDays == 5)
    }

    @Test func yearInReviewRatedAndRereadCountsFromDiaryThisYearOnly() throws {
        let comic = try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        db.setRating(comic, rating: 5)
        #expect(db.exec("UPDATE diary_entries SET logged_at = '2026-03-01 10:00:00' WHERE comic_id = \(comic)"))
        db.restoreDiaryEntry(comicId: comic, rating: 3, review: nil, isReread: true, loggedAt: "2026-04-01 10:00:00")
        db.restoreDiaryEntry(comicId: comic, rating: 4, review: nil, isReread: false, loggedAt: "2024-01-01 10:00:00")

        let review = db.yearInReview(year: 2026)
        #expect(review.ratedCount == 2, "only the two 2026 diary entries should count, not the 2024 one")
        #expect(review.rereadCount == 1)
        #expect(review.averageRating == 4.0, "(5 + 3) / 2")
    }

    @Test("Top rated only surfaces entries logged in the requested year, highest rating first")
    func yearInReviewTopRatedFiltersByYearAndOrdersByRating() throws {
        let batman = try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        let asm = try insertComic(series: "Amazing Spider-Man", issue: "1", title: "ASM #1")
        db.restoreDiaryEntry(comicId: batman, rating: 4, review: nil, isReread: false, loggedAt: "2026-01-01 10:00:00")
        db.restoreDiaryEntry(comicId: asm, rating: 5, review: nil, isReread: false, loggedAt: "2026-02-01 10:00:00")

        let review = db.yearInReview(year: 2026)
        #expect(review.topRated.first?.title == "ASM #1", "5-star should rank above 4-star")
        #expect(review.topRated.count == 2)
    }

    @Test func yearInReviewReturnsZeroesForYearWithNoActivity() throws {
        let comic = try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        logSession(comicId: comic, at: "2025-01-01 10:00:00")

        let review = db.yearInReview(year: 2026)
        #expect(review.issuesRead == 0)
        #expect(review.pagesRead == 0)
        #expect(review.topSeries == nil)
        #expect(review.longestStreakDays == 0)
    }
}
