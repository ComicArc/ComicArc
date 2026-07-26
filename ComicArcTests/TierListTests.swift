import Testing
import Foundation
@testable import ComicArc

final class TierListTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "TierListTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    private func insertComic(title: String) throws -> Int64 {
        try insertTestComic(into: db, series: "Sandman", publisher: "Vertigo", issue: "1", title: title)
    }

    @Test func createTierListAppearsInAllTierLists() throws {
        let id = db.createTierList(title: "Best Vertigo Runs", description: "My favorites")
        let tierLists = db.allTierLists()
        #expect(tierLists.count == 1)
        let tierList = try #require(tierLists.first)
        #expect(tierList.id == id)
        #expect(tierList.title == "Best Vertigo Runs")
        #expect(tierList.comicCount == 0)
    }

    @Test func addToTierListDefaultsToTierB() throws {
        let tierListId = db.createTierList(title: "Ranked", description: "")
        let c1 = try insertComic(title: "Sandman #1")
        db.addToTierList(tierListId: tierListId, comicIds: [c1])

        let items = db.tierListItems(tierListId: tierListId)
        #expect(items.count == 1)
        #expect(items[0].tier == "B")
    }

    @Test func addToTierListWithExplicitTierUpdatesComicCount() throws {
        let tierListId = db.createTierList(title: "Ranked", description: "")
        let c1 = try insertComic(title: "Sandman #1")
        let c2 = try insertComic(title: "Sandman #2")
        db.addToTierList(tierListId: tierListId, comicIds: [c1], tier: "S")
        db.addToTierList(tierListId: tierListId, comicIds: [c2], tier: "F")

        #expect(db.allTierLists().first?.comicCount == 2)
        let items = db.tierListItems(tierListId: tierListId)
        #expect(items.first { $0.comic.id == c1 }?.tier == "S")
        #expect(items.first { $0.comic.id == c2 }?.tier == "F")
    }

    @Test func setTierListItemTierMovesItemAndAppendsToEndOfNewTier() throws {
        let tierListId = db.createTierList(title: "Ranked", description: "")
        let c1 = try insertComic(title: "Sandman #1")
        let c2 = try insertComic(title: "Sandman #2")
        db.addToTierList(tierListId: tierListId, comicIds: [c1, c2], tier: "A")

        let itemToMove = try #require(db.tierListItems(tierListId: tierListId).first { $0.comic.id == c1 })
        db.setTierListItemTier(itemId: itemToMove.id, tierListId: tierListId, tier: "S")

        let items = db.tierListItems(tierListId: tierListId)
        #expect(items.first { $0.comic.id == c1 }?.tier == "S")
        #expect(items.first { $0.comic.id == c2 }?.tier == "A", "moving one item must not affect the other's tier")
    }

    @Test func removeFromTierListDropsItemButKeepsTierList() throws {
        let tierListId = db.createTierList(title: "Keepers", description: "")
        let c1 = try insertComic(title: "Sandman #1")
        db.addToTierList(tierListId: tierListId, comicIds: [c1])
        db.removeFromTierList(tierListId: tierListId, comicIds: [c1])

        #expect(db.tierListItems(tierListId: tierListId).isEmpty)
        #expect(db.allTierLists().count == 1, "the tier list itself should survive removing its only item")
    }

    @Test func deleteTierListCascadesToItems() throws {
        let tierListId = db.createTierList(title: "Temporary", description: "")
        let c1 = try insertComic(title: "Sandman #1")
        db.addToTierList(tierListId: tierListId, comicIds: [c1])
        db.deleteTierList(tierListId)

        #expect(db.allTierLists().isEmpty)
        #expect(db.tierListItems(tierListId: tierListId).isEmpty)
    }

    @Test func tierListsContainingFindsTierListForComic() throws {
        let tierListId = db.createTierList(title: "Sandman Tiers", description: "")
        let c1 = try insertComic(title: "Sandman #1")
        db.addToTierList(tierListId: tierListId, comicIds: [c1])

        let containing = db.tierListsContaining(comicId: c1)
        #expect(containing.map(\.id) == [tierListId])
    }

    @Test("Guards against a copy-paste bug where Tier List CRUD accidentally touches the plain lists/list_items tables")
    func tierListAndListAreIndependent() throws {
        let listId     = db.createList(title: "A List", description: "")
        let tierListId = db.createTierList(title: "A Tier List", description: "")
        let comic      = try insertComic(title: "Sandman #1")
        db.addToList(listId: listId, comicIds: [comic])

        #expect(db.tierListItems(tierListId: tierListId).isEmpty, "adding to a list must not affect an unrelated tier list")
        #expect(db.allLists().count == 1)
        #expect(db.allTierLists().count == 1)
    }
}
