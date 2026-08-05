import Testing
import Foundation
@testable import ComicArc

/// Covers `LibraryScanner.writeComicInfoBack` against real on-disk CBZ fixtures built with the
/// system `zip`/`unzip` tools (not ZIPFoundation directly -- that's only linked into the app
/// targets, not ComicArcTests, and `writeComicInfoBack`'s own signature doesn't leak any
/// ZIPFoundation type, so there's nothing to import here). This does not touch
/// `DatabaseManager.shared` at all -- `writeComicInfoBack` only operates on the file a `Comic`
/// value points to, so it's safe to call directly against `LibraryScanner.shared` in a test.
final class ComicInfoWriteBackTests {
    private let tmpDir: URL

    init() {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ComicInfoWriteBackTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String], cwd: URL) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Builds a real .cbz fixture (a genuine zip file) containing one dummy image and, optionally,
    /// an existing ComicInfo.xml -- returns the fixture's path.
    private func makeFixtureCBZ(name: String, existingComicInfoXML: String? = nil) -> String {
        let workDir = tmpDir.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try! "fake image bytes".write(to: workDir.appendingPathComponent("page1.jpg"), atomically: true, encoding: .utf8)
        if let existingComicInfoXML {
            try! existingComicInfoXML.write(to: workDir.appendingPathComponent("ComicInfo.xml"), atomically: true, encoding: .utf8)
        }
        let cbzPath = tmpDir.appendingPathComponent(name).path
        run("/usr/bin/zip", ["-j", cbzPath, "page1.jpg"] + (existingComicInfoXML != nil ? ["ComicInfo.xml"] : []), cwd: workDir)
        return cbzPath
    }

    private func extractedComicInfoXML(fromCBZAt path: String) -> String? {
        let outDir = tmpDir.appendingPathComponent("extract-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        run("/usr/bin/unzip", ["-o", path, "-d", outDir.path], cwd: tmpDir)
        return try? String(contentsOf: outDir.appendingPathComponent("ComicInfo.xml"), encoding: .utf8)
    }

    private func makeComic(filePath: String, title: String = "Batman #1", series: String = "Batman",
                          publisher: String = "DC", issueNumber: String? = "1", writer: String? = nil,
                          penciller: String? = nil, volume: String? = nil, year: Int? = nil) -> Comic {
        Comic(id: 1, title: title, filePath: filePath, publisher: publisher, character: nil,
              series: series, issueNumber: issueNumber, pageCount: 1, writer: writer, penciller: penciller,
              year: year, volume: volume, format: nil, storyArc: nil, languageIso: nil, notes: nil,
              addedAt: "", deletedAt: nil, position: 0, fileHash: nil)
    }

    @Test func writesANewComicInfoXMLWhenNoneExists() throws {
        let path = makeFixtureCBZ(name: "new.cbz")
        let comic = makeComic(filePath: path, writer: "Frank Miller")

        try LibraryScanner.shared.writeComicInfoBack(comic: comic).get()

        let xml = try #require(extractedComicInfoXML(fromCBZAt: path))
        #expect(xml.contains("<Series>Batman</Series>"))
        #expect(xml.contains("<Title>Batman #1</Title>"))
        #expect(xml.contains("<IssueNumber>1</IssueNumber>"))
        #expect(xml.contains("<Publisher>DC</Publisher>"))
        #expect(xml.contains("<Writer>Frank Miller</Writer>"))
    }

    @Test func preservesFieldsItDoesNotManageOnAnExistingComicInfoXML() throws {
        let existing = """
            <?xml version="1.0" encoding="utf-8"?>
            <ComicInfo><Summary>A dark and stormy night.</Summary><LanguageISO>en</LanguageISO></ComicInfo>
            """
        let path = makeFixtureCBZ(name: "existing.cbz", existingComicInfoXML: existing)
        let comic = makeComic(filePath: path)

        try LibraryScanner.shared.writeComicInfoBack(comic: comic).get()

        let xml = try #require(extractedComicInfoXML(fromCBZAt: path))
        #expect(xml.contains("A dark and stormy night."), "unmanaged fields must survive a write-back")
        #expect(xml.contains("<LanguageISO>en</LanguageISO>"))
        #expect(xml.contains("<Series>Batman</Series>"), "managed fields must still be written")
    }

    @Test func replacesAStaleManagedFieldRatherThanDuplicatingIt() throws {
        let existing = "<?xml version=\"1.0\"?><ComicInfo><Series>Wrong Series</Series></ComicInfo>"
        let path = makeFixtureCBZ(name: "stale.cbz", existingComicInfoXML: existing)
        let comic = makeComic(filePath: path, series: "Correct Series")

        try LibraryScanner.shared.writeComicInfoBack(comic: comic).get()

        let xml = try #require(extractedComicInfoXML(fromCBZAt: path))
        #expect(xml.contains("<Series>Correct Series</Series>"))
        #expect(xml.contains("Wrong Series") == false)
        #expect(xml.components(separatedBy: "<Series>").count == 2, "must not end up with two <Series> elements")
    }

    @Test func rejectsNonCBZFiles() throws {
        let comic = makeComic(filePath: "/tmp/whatever.cbr")
        let result = LibraryScanner.shared.writeComicInfoBack(comic: comic)
        guard case .failure(.notACBZ) = result else { Issue.record("expected .notACBZ, got \(result)"); return }
    }

    @Test func omitsEmptyOptionalFieldsRatherThanWritingBlankElements() throws {
        let path = makeFixtureCBZ(name: "sparse.cbz")
        let comic = makeComic(filePath: path, issueNumber: nil, writer: nil, penciller: nil, volume: nil, year: nil)

        try LibraryScanner.shared.writeComicInfoBack(comic: comic).get()

        let xml = try #require(extractedComicInfoXML(fromCBZAt: path))
        #expect(xml.contains("<Writer>") == false)
        #expect(xml.contains("<Volume>") == false)
        #expect(xml.contains("<Year>") == false)
    }
}
