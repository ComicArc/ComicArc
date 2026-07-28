import Testing
import Foundation
@testable import ComicArc

final class TagCategoryTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "TagCategoryTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    private func insertComic(title: String) throws -> Int64 {
        try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: title)
    }

    @Test func addTagDefaultsToCustomCategory() throws {
        let id = try insertComic(title: "Batman #1")
        db.addTag(name: "favorites", to: id)

        let tags = db.tags(for: id)
        #expect(tags.count == 1)
        #expect(try #require(tags.first).category == TagCategory.custom.rawValue)
    }

    @Test func addTagWithExplicitCategoryPersists() throws {
        let id = try insertComic(title: "Batman #1")
        db.addTag(name: "noir", to: id, category: .genre)

        let tags = db.tags(for: id)
        #expect(try #require(tags.first).category == "Genre")
    }

    @Test("Re-adding an existing tag to another comic must not change its category")
    func addingExistingTagToAnotherComicDoesNotChangeItsCategory() throws {
        let c1 = try insertComic(title: "Batman #1")
        let c2 = try insertComic(title: "Batman #2")
        db.addTag(name: "noir", to: c1, category: .genre)
        db.addTag(name: "noir", to: c2, category: .mood)  // re-adding the same tag name with a different category

        let tagOnC1 = try #require(db.tags(for: c1).first)
        let tagOnC2 = try #require(db.tags(for: c2).first)
        #expect(tagOnC1.category == "Genre", "the tag's category is set once, on creation")
        #expect(tagOnC2.category == "Genre", "linking an existing tag to another comic must not silently recategorize it")
    }

    @Test func allTagsIncludesCategory() throws {
        let id = try insertComic(title: "Batman #1")
        db.addTag(name: "hardcover", to: id, category: .format)

        let all = db.allTags()
        #expect(all.count == 1)
        let first = try #require(all.first)
        #expect(first.tag.category == "Format")
        #expect(first.count == 1)
    }

    @Test func renameTagSimpleCaseUpdatesNameEverywhere() throws {
        let c1 = try insertComic(title: "Batman #1")
        let c2 = try insertComic(title: "Batman #2")
        db.addTag(name: "scifi", to: c1, category: .genre)
        db.addTag(name: "scifi", to: c2, category: .genre)
        let tagId = try #require(db.tags(for: c1).first).id

        db.renameTag(id: tagId, newName: "sci-fi")

        #expect(db.tags(for: c1).map(\.name) == ["sci-fi"])
        #expect(db.tags(for: c2).map(\.name) == ["sci-fi"])
        #expect(db.allTags().count == 1, "renaming must not leave a duplicate tag row behind")
    }

    @Test func renameTagCollidingWithExistingTagMergesInsteadOfErroring() throws {
        let c1 = try insertComic(title: "Batman #1")
        let c2 = try insertComic(title: "Batman #2")
        db.addTag(name: "scifi", to: c1, category: .genre)
        db.addTag(name: "sci-fi", to: c2, category: .genre)
        let scifiId = try #require(db.tags(for: c1).first).id

        db.renameTag(id: scifiId, newName: "sci-fi")

        #expect(db.allTags().count == 1, "the two tags must merge into one, not collide")
        #expect(db.tags(for: c1).map(\.name) == ["sci-fi"])
        #expect(db.tags(for: c2).map(\.name) == ["sci-fi"])
        #expect(db.allTags().first?.count == 2, "both comics should now share the single merged tag")
    }

    @Test("Merging colliding tag names when one comic already has both tags must not error on the resulting comic_tags PRIMARY KEY collision for that one row")
    func renameTagCollidingWhereOneComicHasBothTagsStillMergesCleanly() throws {
        let c1 = try insertComic(title: "Batman #1")
        db.addTag(name: "scifi", to: c1, category: .genre)
        db.addTag(name: "sci-fi", to: c1, category: .genre)
        let scifiId = try #require(db.tags(for: c1).first { $0.name == "scifi" }).id

        db.renameTag(id: scifiId, newName: "sci-fi")

        #expect(db.tags(for: c1).map(\.name) == ["sci-fi"], "c1 should end up with exactly one copy of the merged tag")
        #expect(db.allTags().count == 1)
    }

    @Test func deleteTagGloballyRemovesFromEveryComic() throws {
        let c1 = try insertComic(title: "Batman #1")
        let c2 = try insertComic(title: "Batman #2")
        db.addTag(name: "noir", to: c1, category: .genre)
        db.addTag(name: "noir", to: c2, category: .genre)
        let tagId = db.tags(for: c1)[0].id

        db.deleteTagGlobally(id: tagId)

        #expect(db.tags(for: c1).isEmpty)
        #expect(db.tags(for: c2).isEmpty)
        #expect(db.allTags().isEmpty)
    }

    @Test func setTagCategoryUpdatesCategoryAcrossAllComics() throws {
        let c1 = try insertComic(title: "Batman #1")
        let c2 = try insertComic(title: "Batman #2")
        db.addTag(name: "noir", to: c1, category: .genre)
        db.addTag(name: "noir", to: c2, category: .genre)
        let tagId = try #require(db.tags(for: c1).first).id

        db.setTagCategory(id: tagId, category: .mood)

        #expect(db.tags(for: c1)[0].category == "Mood")
        #expect(db.tags(for: c2)[0].category == "Mood")
    }
}
