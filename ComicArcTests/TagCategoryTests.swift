import XCTest
@testable import ComicArc

final class TagCategoryTests: XCTestCase {
    private var db: DatabaseManager!
    private var tempPath: String!

    override func setUp() {
        super.setUp()
        tempPath = NSTemporaryDirectory() + "TagCategoryTests-\(UUID().uuidString).sqlite"
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

    func test_addTag_defaultsToCustomCategory() {
        let id = insertComic(title: "Batman #1")
        db.addTag(name: "favorites", to: id)

        let tags = db.tags(for: id)
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].category, TagCategory.custom.rawValue)
    }

    func test_addTag_withExplicitCategory_persists() {
        let id = insertComic(title: "Batman #1")
        db.addTag(name: "noir", to: id, category: .genre)

        let tags = db.tags(for: id)
        XCTAssertEqual(tags[0].category, "Genre")
    }

    func test_addingExistingTagToAnotherComic_doesNotChangeItsCategory() {
        let c1 = insertComic(title: "Batman #1")
        let c2 = insertComic(title: "Batman #2")
        db.addTag(name: "noir", to: c1, category: .genre)
        db.addTag(name: "noir", to: c2, category: .mood)  // re-adding the same tag name with a different category

        let tagsOnC1 = db.tags(for: c1)
        let tagsOnC2 = db.tags(for: c2)
        XCTAssertEqual(tagsOnC1[0].category, "Genre", "the tag's category is set once, on creation")
        XCTAssertEqual(tagsOnC2[0].category, "Genre", "linking an existing tag to another comic must not silently recategorize it")
    }

    func test_allTags_includesCategory() {
        let id = insertComic(title: "Batman #1")
        db.addTag(name: "hardcover", to: id, category: .format)

        let all = db.allTags()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].tag.category, "Format")
        XCTAssertEqual(all[0].count, 1)
    }
}
