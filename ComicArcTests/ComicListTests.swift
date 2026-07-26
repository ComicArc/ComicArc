import Testing
import Foundation
@testable import ComicArc

final class ComicListTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "ComicListTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    private func insertComic(title: String) throws -> Int64 {
        try insertTestComic(into: db, series: "Sandman", publisher: "Vertigo", issue: "1", title: title)
    }

    @Test func createListAppearsInAllLists() throws {
        let id = db.createList(title: "Best Vertigo Runs", description: "My favorites")
        let lists = db.allLists()
        #expect(lists.count == 1)
        let list = try #require(lists.first)
        #expect(list.id == id)
        #expect(list.title == "Best Vertigo Runs")
        #expect(list.comicCount == 0)
    }

    @Test func addToListUpdatesComicCountAndItems() throws {
        let listId = db.createList(title: "Top 5", description: "")
        let c1 = try insertComic(title: "Sandman #1")
        let c2 = try insertComic(title: "Sandman #2")
        db.addToList(listId: listId, comicIds: [c1, c2])

        #expect(db.allLists().first?.comicCount == 2)
        let items = db.listItems(listId: listId)
        #expect(items.map(\.comic.id) == [c1, c2])
        #expect(items.map(\.position) == [0, 1])
    }

    @Test func reorderListChangesRankOrder() throws {
        let listId = db.createList(title: "Ranked", description: "")
        let c1 = try insertComic(title: "Sandman #1")
        let c2 = try insertComic(title: "Sandman #2")
        db.addToList(listId: listId, comicIds: [c1, c2])

        let items = db.listItems(listId: listId)
        db.reorderList(listId: listId, orderedIds: [items[1].id, items[0].id])

        let reordered = db.listItems(listId: listId)
        #expect(reordered.map(\.comic.id) == [c2, c1], "c2 should now rank first")
    }

    @Test func removeFromListDropsItemButKeepsList() throws {
        let listId = db.createList(title: "Keepers", description: "")
        let c1 = try insertComic(title: "Sandman #1")
        db.addToList(listId: listId, comicIds: [c1])
        db.removeFromList(listId: listId, comicIds: [c1])

        #expect(db.listItems(listId: listId).isEmpty)
        #expect(db.allLists().count == 1, "the list itself should survive removing its only item")
    }

    @Test func deleteListCascadesToListItems() throws {
        let listId = db.createList(title: "Temporary", description: "")
        let c1 = try insertComic(title: "Sandman #1")
        db.addToList(listId: listId, comicIds: [c1])
        db.deleteList(listId)

        #expect(db.allLists().isEmpty)
        #expect(db.listItems(listId: listId).isEmpty)
    }

    @Test func listsContainingFindsListForComic() throws {
        let listId = db.createList(title: "Sandman List", description: "")
        let c1 = try insertComic(title: "Sandman #1")
        db.addToList(listId: listId, comicIds: [c1])

        let containing = db.listsContaining(comicId: c1)
        #expect(containing.map(\.id) == [listId])
    }

    @Test func setListRatingPersistsRatingAndReview() throws {
        let listId = db.createList(title: "Rated List", description: "")
        db.setListRating(listId, rating: 5, review: "Perfect collection.")

        let list = try #require(db.allLists().first)
        #expect(list.rating == 5)
        #expect(list.review == "Perfect collection.")
    }

    @Test("Guards against a copy-paste bug where List CRUD accidentally touches the runs/run_items tables")
    func listAndRunAreIndependent() throws {
        let runId  = db.createRun(title: "A Run", description: "")
        let listId = db.createList(title: "A List", description: "")
        let comic  = try insertComic(title: "Sandman #1")
        db.addToRun(runId: runId, comicIds: [comic])

        #expect(db.listItems(listId: listId).isEmpty, "adding to a run must not affect an unrelated list")
        #expect(db.allRuns().count == 1)
        #expect(db.allLists().count == 1)
    }
}
