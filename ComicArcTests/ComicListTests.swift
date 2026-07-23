import XCTest
@testable import ComicArc

final class ComicListTests: XCTestCase {
    private var db: DatabaseManager!
    private var tempPath: String!

    override func setUp() {
        super.setUp()
        tempPath = NSTemporaryDirectory() + "ComicListTests-\(UUID().uuidString).sqlite"
        db = DatabaseManager(dbPath: tempPath)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: tempPath)
        super.tearDown()
    }

    private func insertComic(title: String) -> Int64 {
        db.batchInsert([DatabaseManager.ComicInsert(
            title: title, filePath: "/tmp/\(UUID().uuidString).cbz", publisher: "Vertigo",
            character: nil, series: "Sandman", issueNumber: "1", pageCount: 20,
            writer: nil, penciller: nil, year: nil, storyArc: nil, languageIso: nil, fileHash: nil
        )])
        return db.allComics(series: "Sandman", sortOrder: .manual).first { $0.title == title }!.id
    }

    func test_createList_appearsInAllLists() {
        let id = db.createList(title: "Best Vertigo Runs", description: "My favorites")
        let lists = db.allLists()
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(lists[0].id, id)
        XCTAssertEqual(lists[0].title, "Best Vertigo Runs")
        XCTAssertEqual(lists[0].comicCount, 0)
    }

    func test_addToList_updatesComicCountAndItems() {
        let listId = db.createList(title: "Top 5", description: "")
        let c1 = insertComic(title: "Sandman #1")
        let c2 = insertComic(title: "Sandman #2")
        db.addToList(listId: listId, comicIds: [c1, c2])

        XCTAssertEqual(db.allLists().first?.comicCount, 2)
        let items = db.listItems(listId: listId)
        XCTAssertEqual(items.map(\.comic.id), [c1, c2])
        XCTAssertEqual(items.map(\.position), [0, 1])
    }

    func test_reorderList_changesRankOrder() {
        let listId = db.createList(title: "Ranked", description: "")
        let c1 = insertComic(title: "Sandman #1")
        let c2 = insertComic(title: "Sandman #2")
        db.addToList(listId: listId, comicIds: [c1, c2])

        let items = db.listItems(listId: listId)
        db.reorderList(listId: listId, orderedIds: [items[1].id, items[0].id])

        let reordered = db.listItems(listId: listId)
        XCTAssertEqual(reordered.map(\.comic.id), [c2, c1], "c2 should now rank first")
    }

    func test_removeFromList_dropsItemButKeepsList() {
        let listId = db.createList(title: "Keepers", description: "")
        let c1 = insertComic(title: "Sandman #1")
        db.addToList(listId: listId, comicIds: [c1])
        db.removeFromList(listId: listId, comicIds: [c1])

        XCTAssertTrue(db.listItems(listId: listId).isEmpty)
        XCTAssertEqual(db.allLists().count, 1, "the list itself should survive removing its only item")
    }

    func test_deleteList_cascadesToListItems() {
        let listId = db.createList(title: "Temporary", description: "")
        let c1 = insertComic(title: "Sandman #1")
        db.addToList(listId: listId, comicIds: [c1])
        db.deleteList(listId)

        XCTAssertTrue(db.allLists().isEmpty)
        XCTAssertTrue(db.listItems(listId: listId).isEmpty)
    }

    func test_listsContaining_findsListForComic() {
        let listId = db.createList(title: "Sandman List", description: "")
        let c1 = insertComic(title: "Sandman #1")
        db.addToList(listId: listId, comicIds: [c1])

        let containing = db.listsContaining(comicId: c1)
        XCTAssertEqual(containing.map(\.id), [listId])
    }

    func test_setListRating_persistsRatingAndReview() {
        let listId = db.createList(title: "Rated List", description: "")
        db.setListRating(listId, rating: 5, review: "Perfect collection.")

        let list = db.allLists().first!
        XCTAssertEqual(list.rating, 5)
        XCTAssertEqual(list.review, "Perfect collection.")
    }

    func test_listAndRunAreIndependent() {
        // Guards against a copy-paste bug where List CRUD accidentally touches the runs/run_items tables.
        let runId  = db.createRun(title: "A Run", description: "")
        let listId = db.createList(title: "A List", description: "")
        let comic  = insertComic(title: "Sandman #1")
        db.addToRun(runId: runId, comicIds: [comic])

        XCTAssertTrue(db.listItems(listId: listId).isEmpty, "adding to a run must not affect an unrelated list")
        XCTAssertEqual(db.allRuns().count, 1)
        XCTAssertEqual(db.allLists().count, 1)
    }
}
