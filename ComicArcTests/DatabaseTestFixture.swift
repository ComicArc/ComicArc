import Foundation
import Testing
@testable import ComicArc

/// Creates a fresh, isolated on-disk `DatabaseManager` for a test suite. Each `@Test` gets its
/// own suite instance under Swift Testing's parallel-by-default model, so `init()` calling this
/// (and `deinit` removing the file at the returned path) replaces XCTest's `setUp`/`tearDown`
/// without any suite sharing state with another.
func makeTestDatabase(name: String) -> (db: DatabaseManager, path: String) {
    let path = NSTemporaryDirectory() + "\(name)-\(UUID().uuidString).sqlite"
    return (DatabaseManager(dbPath: path), path)
}

/// Inserts a single comic with the given fields, returning the row's assigned id. Shared by every
/// test suite that needs real `comics` rows, so the `ComicInsert` field list only needs updating
/// in one place. `@discardableResult` since several suites don't need the id back.
@discardableResult
func insertTestComic(
    into db: DatabaseManager,
    series: String, publisher: String, issue: String?,
    title: String, filePath: String? = nil, pageCount: Int = 20,
    writer: String? = nil, year: Int? = nil, month: Int? = nil, day: Int? = nil,
    storyArc: String? = nil, fileHash: String? = nil,
    comicInfoIssueNumber: String? = nil, volume: String? = nil,
    format: String? = nil, alternateNumber: String? = nil, hasComicInfo: Bool? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Int64 {
    db.batchInsert([DatabaseManager.ComicInsert(
        title: title, filePath: filePath ?? "/tmp/\(UUID().uuidString).cbz", publisher: publisher,
        character: nil, series: series, issueNumber: issue, pageCount: pageCount,
        writer: writer, penciller: nil, year: year, storyArc: storyArc, languageIso: nil, fileHash: fileHash,
        coverMonth: month, coverDay: day, alternateNumber: alternateNumber,
        comicInfoIssueNumber: comicInfoIssueNumber, volume: volume, format: format,
        hasComicInfo: hasComicInfo
    )])
    return try #require(
        db.allComics(series: series, sortOrder: .manual).first { $0.title == title },
        sourceLocation: sourceLocation
    ).id
}
