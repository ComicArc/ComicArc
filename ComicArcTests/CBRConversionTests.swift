import Testing
import Foundation
@testable import ComicArc

/// Covers the database side of CBR-to-CBZ conversion (`cbrComics()`, `updateFilePathAndHash`) --
/// the actual archive conversion itself (`LibraryScanner.convertCBRToCBZ`) needs a real `unar`
/// binary and a real RAR fixture, neither available in a unit test environment, so that part is
/// exercised only by hand against the live app, same as this project's other `unar`-dependent code.
final class CBRConversionTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "CBRConversionTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    @Test func cbrComicsReturnsOnlyCBRFiles() throws {
        try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                            title: "Batman #1", filePath: "/tmp/Batman 001.cbr")
        try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "2",
                            title: "Batman #2", filePath: "/tmp/Batman 002.cbz")
        try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "3",
                            title: "Batman #3", filePath: "/tmp/Batman 003.pdf")

        let cbrComics = db.cbrComics()
        #expect(cbrComics.count == 1)
        #expect(cbrComics.first?.title == "Batman #1")
    }

    @Test func cbrComicsIsCaseInsensitiveOnExtension() throws {
        try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                            title: "Batman #1", filePath: "/tmp/Batman 001.CBR")

        #expect(db.cbrComics().count == 1)
    }

    @Test func updateFilePathAndHashUpdatesBothFields() throws {
        let id = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                                     title: "Batman #1", filePath: "/tmp/Batman 001.cbr", fileHash: "old-hash")

        db.updateFilePathAndHash(id: id, newPath: "/tmp/Batman 001.cbz", newHash: "new-hash")

        let comic = try #require(db.comic(id: id))
        #expect(comic.filePath == "/tmp/Batman 001.cbz")
        #expect(db.idForHash("new-hash") == id)
        #expect(db.idForHash("old-hash") == nil)
    }

    @Test func convertedComicNoLongerAppearsInCBRComics() throws {
        let id = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                                     title: "Batman #1", filePath: "/tmp/Batman 001.cbr")

        db.updateFilePathAndHash(id: id, newPath: "/tmp/Batman 001.cbz", newHash: "new-hash")

        #expect(db.cbrComics().isEmpty)
    }
}
