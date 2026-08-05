import Testing
import Foundation
@testable import ComicArc

/// Covers `LibraryViewModel.computeRecommendations`, the pure taste-based discovery heuristic --
/// exposed as an `internal static` function (not `private`) specifically so it's testable without
/// instantiating `LibraryViewModel` itself, which triggers a live filesystem scan on construction.
final class RecommendationTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "RecommendationTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    @Test func returnsEmptyWhenNothingIsHighlyRated() throws {
        try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        #expect(LibraryViewModel.computeRecommendations(db: db).isEmpty)
    }

    @Test func recommendsUnreadComicSharingATagWithAHighlyRatedComic() throws {
        let liked = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        db.setRating(liked, rating: 5)
        db.addTag(name: "Noir", to: liked)

        let candidate = try insertTestComic(into: db, series: "Daredevil", publisher: "Marvel", issue: "1", title: "Daredevil #1")
        db.addTag(name: "Noir", to: candidate)

        let recs = LibraryViewModel.computeRecommendations(db: db)
        #expect(recs.map(\.id) == [candidate])
    }

    @Test func excludesComicsFromASeriesAlreadyRepresentedInTheLikedSet() throws {
        let liked = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        db.setRating(liked, rating: 5)
        db.addTag(name: "Noir", to: liked)

        // Same series as the liked comic -- this is readNextSuggestions' job, not recommendations'.
        let sameSeries = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "2", title: "Batman #2")
        db.addTag(name: "Noir", to: sameSeries)

        #expect(LibraryViewModel.computeRecommendations(db: db).isEmpty)
    }

    @Test func excludesComicsWithNoOverlapAtAll() throws {
        let liked = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        db.setRating(liked, rating: 5)
        db.addTag(name: "Noir", to: liked)

        _ = try insertTestComic(into: db, series: "Saga", publisher: "Image", issue: "1", title: "Saga #1")

        #expect(LibraryViewModel.computeRecommendations(db: db).isEmpty)
    }

    @Test func excludesAlreadyStartedComics() throws {
        let liked = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        db.setRating(liked, rating: 5)
        db.addTag(name: "Noir", to: liked)

        let inProgress = try insertTestComic(into: db, series: "Daredevil", publisher: "Marvel", issue: "1", title: "Daredevil #1")
        db.addTag(name: "Noir", to: inProgress)
        db.updateProgress(comicId: inProgress, page: 3)

        #expect(LibraryViewModel.computeRecommendations(db: db).isEmpty)
    }

    @Test func sharedWriterAloneIsEnoughToRecommend() throws {
        let liked = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                                        title: "Batman #1", writer: "Ed Brubaker")
        db.setRating(liked, rating: 4)

        let candidate = try insertTestComic(into: db, series: "Criminal", publisher: "Image", issue: "1",
                                            title: "Criminal #1", writer: "Ed Brubaker")

        let recs = LibraryViewModel.computeRecommendations(db: db)
        #expect(recs.map(\.id) == [candidate])
    }

    @Test func ratingBelowFourDoesNotContributeToTheTasteProfile() throws {
        let liked = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        db.setRating(liked, rating: 3)
        db.addTag(name: "Noir", to: liked)

        let candidate = try insertTestComic(into: db, series: "Daredevil", publisher: "Marvel", issue: "1", title: "Daredevil #1")
        db.addTag(name: "Noir", to: candidate)

        #expect(LibraryViewModel.computeRecommendations(db: db).isEmpty)
    }

    @Test func tagOverlapOutranksPublisherOnlyOverlap() throws {
        let liked = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1")
        db.setRating(liked, rating: 5)
        db.addTag(name: "Noir", to: liked)

        let tagMatch = try insertTestComic(into: db, series: "Daredevil", publisher: "Marvel", issue: "1", title: "Daredevil #1")
        db.addTag(name: "Noir", to: tagMatch)

        let publisherOnlyMatch = try insertTestComic(into: db, series: "Superman", publisher: "DC", issue: "1", title: "Superman #1")

        let recs = LibraryViewModel.computeRecommendations(db: db)
        #expect(recs.first?.id == tagMatch)
        #expect(recs.map(\.id).contains(publisherOnlyMatch))
    }
}
