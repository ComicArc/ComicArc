import XCTest
@testable import ComicArc

// MARK: - Pure engine tests (no database involved)

final class ReadingOrderEngineTests: XCTestCase {

    // MARK: Classification

    func test_classify_regularIssue() {
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: "12", title: "Batman #12", series: "Batman"), .regular)
    }

    func test_classify_annual() {
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: "1", title: "Batman Annual #1", series: "Batman"), .annual)
    }

    func test_classify_oneShot() {
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: nil, title: "Batman: Full Circle One-Shot", series: "Batman"), .oneShot)
    }

    func test_classify_giantSizeDoesNotOverrideAnnual() {
        // "most-specific-first" ordering: a Giant-Size Annual should classify as annual, the
        // rarer/more meaningful label, not giant-size.
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: "1", title: "X-Men Giant-Size Annual #1", series: "X-Men"), .annual)
    }

    func test_classify_alphaOmega() {
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: "Alpha", title: "Infinity Alpha", series: "Infinity"), .alpha)
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: "Omega", title: "Infinity Omega", series: "Infinity"), .omega)
    }

    func test_classify_issueZero() {
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: "0", title: "Batman #0", series: "Batman"), .issueZero)
    }

    func test_classify_pointIssue() {
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: "12.1", title: "Batman #12.1", series: "Batman"), .pointIssue)
    }

    func test_classify_fcbdAndAshcan() {
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: nil, title: "Batman FCBD Special Edition", series: "Batman"), .fcbd)
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: nil, title: "Batman Ashcan Edition", series: "Batman"), .ashcan)
    }

    func test_classify_formatOnlyTypesDoNotNeedPlacement() {
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: nil, title: "Batman Vol. 1 TPB", series: "Batman").needsPlacement, false)
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: nil, title: "Batman Omnibus", series: "Batman").needsPlacement, false)
    }

    func test_classify_specialTypesNeedPlacement() {
        XCTAssertTrue(ComicType.annual.needsPlacement)
        XCTAssertTrue(ComicType.oneShot.needsPlacement)
        XCTAssertFalse(ComicType.regular.needsPlacement)
    }

    // MARK: parseLegacyNumber

    func test_parseLegacyNumber_integer() {
        XCTAssertEqual(ReadingOrderEngine.parseLegacyNumber("700"), 700)
    }

    func test_parseLegacyNumber_decimal() {
        XCTAssertEqual(ReadingOrderEngine.parseLegacyNumber("12.1"), 12.1)
    }

    func test_parseLegacyNumber_nonNumericReturnsNil() {
        XCTAssertNil(ReadingOrderEngine.parseLegacyNumber("Alpha"))
        XCTAssertNil(ReadingOrderEngine.parseLegacyNumber(nil))
        XCTAssertNil(ReadingOrderEngine.parseLegacyNumber(""))
    }

    // MARK: Placement tiers

    private func input(_ id: Int64, group: String = "Marvel:ASM", num: Double? = nil,
                        type: ComicType = .regular, year: Int? = nil, month: Int? = nil, day: Int? = nil,
                        arc: String? = nil, title: String = "") -> ReadingOrderEngine.ReadingOrderInput {
        .init(id: id, groupKey: group, legacyNumber: num, comicType: type,
              year: year, month: month, day: day, storyArc: arc, title: title)
    }

    func test_tier1_fullDateInterpolation() {
        let inputs = [
            input(1, num: 12, year: 2005, month: 6, title: "#12"),
            input(2, num: 13, year: 2005, month: 9, title: "#13"),
            input(3, type: .annual, year: 2005, month: 8, title: "Annual #1"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)
        XCTAssertEqual(results[3]?.confidence, 100)
        XCTAssertGreaterThan(results[3]!.position, results[1]!.position)
        XCTAssertLessThan(results[3]!.position, results[2]!.position)
    }

    func test_tier2_singleDateAnchor() {
        let inputs = [
            input(1, num: 12, year: 2005, month: 6, title: "#12"),
            input(2, num: 13, title: "#13"), // no date
            input(3, type: .annual, year: 2005, month: 8, title: "Annual #1"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)
        // Only one dated mainline neighbor available — special's date (Aug 2005) is after it
        // (June 2005), so it should land after, with reduced confidence vs. tier 1.
        XCTAssertEqual(results[3]?.confidence, 85)
        XCTAssertGreaterThan(results[3]!.position, results[1]!.position)
    }

    func test_tier3_storyArcAdjacency() {
        let inputs = [
            input(1, num: 12, arc: "No Man's Land", title: "#12"),
            input(2, num: 13, title: "#13"),
            input(3, type: .special, arc: "No Man's Land", title: "Special #1"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)
        XCTAssertEqual(results[3]?.confidence, 85)
        XCTAssertEqual(results[3]?.position, results[1]!.position + 1)
    }

    func test_tier3_storyArcDoesNotMatchAcrossGroups() {
        // Same arc name, different series — must not match; arc names aren't globally unique.
        let inputs = [
            input(1, group: "Marvel:ASM", num: 12, arc: "Rebirth", title: "ASM #12"),
            input(2, group: "DC:Flash", num: 5, arc: "Rebirth", title: "Flash #5"),
            input(3, group: "DC:Flash", num: 6, title: "Flash #6"),
            input(4, group: "DC:Flash", type: .special, arc: "Rebirth", title: "Flash Special"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)
        // The Flash special should match Flash #5 (same group), not ASM #12 (different group,
        // same arc name, would be a false positive if grouping weren't respected).
        XCTAssertEqual(results[4]?.position, results[2]!.position + 1)
    }

    func test_tier4_proportionalSpreadWhenNoOtherSignal() {
        let inputs = (1...20).map { input(Int64($0), num: Double($0), title: "#\($0)") } + [
            input(101, num: 1, type: .annual, title: "Annual #1"),
            input(102, num: 2, type: .annual, title: "Annual #2"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)
        XCTAssertEqual(results[101]?.confidence, 60)
        XCTAssertEqual(results[102]?.confidence, 60)
        // Annual #1 should land before Annual #2 (deterministic sequence order).
        XCTAssertLessThan(results[101]!.position, results[102]!.position)
        // Both should land strictly within the mainline range, not at the very end.
        XCTAssertLessThan(results[102]!.position, results[20]!.position)
    }

    func test_tier5_alwaysLastWhenNoMainlineSiblings() {
        let inputs = [
            input(1, group: "Solo:Annuals", num: 1, type: .annual, title: "Annual #1"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)
        XCTAssertEqual(results[1]?.confidence, 0)
        XCTAssertGreaterThanOrEqual(results[1]!.position, ReadingOrderEngine.alwaysLastBand)
    }

    func test_tier4_deterministicAcrossRepeatedRuns() {
        let inputs = (1...10).map { input(Int64($0), num: Double($0), title: "#\($0)") } + [
            input(101, num: 3, type: .annual, title: "Annual #3"),
            input(102, num: 1, type: .annual, title: "Annual #1"),
            input(103, num: 2, type: .annual, title: "Annual #2"),
        ]
        let first  = ReadingOrderEngine.computeSeriesPositions(inputs)
        let second = ReadingOrderEngine.computeSeriesPositions(inputs)
        for id in [101, 102, 103] {
            XCTAssertEqual(first[Int64(id)]?.position, second[Int64(id)]?.position)
        }
        // And sequence order should reflect the annuals' own numbers, not insertion order.
        XCTAssertLessThan(first[102]!.position, first[103]!.position)
        XCTAssertLessThan(first[103]!.position, first[101]!.position)
    }

    func test_decimalPointIssueGetsOwnSlotBetweenNeighbors() {
        let inputs = [
            input(1, num: 12, title: "#12"),
            input(2, num: 12.1, type: .pointIssue, title: "#12.1"),
            input(3, num: 13, title: "#13"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)
        // Point issues are regular-ish (needsPlacement is false only for format-only types) —
        // .pointIssue.needsPlacement is true, so it goes through placement tiers, not direct
        // mainline positioning. With no date/arc signal and only 2 non-special mainline
        // siblings, it should land in the proportional band between them.
        XCTAssertGreaterThan(results[2]!.position, results[1]!.position)
        XCTAssertLessThan(results[2]!.position, results[3]!.position)
    }
}

// MARK: - DB integration tests

// The rest of this test suite has no existing convention for DB-layer testing (no
// setUp/tearDown, no in-memory test DB — every other test file exercises pure logic only).
// DatabaseManager's new `init(dbPath:)` overload (added alongside the no-arg initializer
// DatabaseManager.shared uses) makes this possible: each test gets its own throwaway SQLite
// file instead of touching the real, shared library database.
final class ReadingOrderEngineDatabaseTests: XCTestCase {
    private var db: DatabaseManager!
    private var tempPath: String!

    override func setUp() {
        super.setUp()
        tempPath = NSTemporaryDirectory() + "ReadingOrderEngineTests-\(UUID().uuidString).sqlite"
        db = DatabaseManager(dbPath: tempPath)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: tempPath)
        super.tearDown()
    }

    private func insertComic(series: String, publisher: String = "Marvel", issue: String?,
                              title: String, year: Int? = nil, month: Int? = nil) {
        db.batchInsert([DatabaseManager.ComicInsert(
            title: title, filePath: "/tmp/\(UUID().uuidString).cbz", publisher: publisher,
            character: nil, series: series, issueNumber: issue, pageCount: 20,
            writer: nil, penciller: nil, year: year, storyArc: nil, languageIso: nil, fileHash: nil,
            coverMonth: month
        )])
    }

    func test_recomputeReadingOrder_movesAnnualOutOfAlwaysLastBand() {
        for n in 1...20 { insertComic(series: "ASM", issue: "\(n)", title: "ASM #\(n)") }
        insertComic(series: "ASM", issue: "1", title: "ASM Annual #1")
        db.recomputeReadingOrder()

        let comics = db.allComics(series: "ASM", sortOrder: .manual)
        let annual = comics.first { $0.title.contains("Annual") }
        XCTAssertNotNil(annual?.readingOrderPosition)
        XCTAssertNotNil(annual?.readingOrderConfidence)
        // With 20 mainline siblings and no date data, it should land in the proportional
        // band (confidence 60), not the always-last safety net (confidence 0).
        XCTAssertEqual(annual?.readingOrderConfidence, 60)
    }

    func test_recomputeReadingOrder_isIdempotent() {
        for n in 1...5 { insertComic(series: "Batman", issue: "\(n)", title: "Batman #\(n)") }
        insertComic(series: "Batman", issue: "1", title: "Batman Annual #1")
        db.recomputeReadingOrder()
        let first = db.allComics(series: "Batman", sortOrder: .manual).map(\.readingOrderPosition)
        db.recomputeReadingOrder()
        let second = db.allComics(series: "Batman", sortOrder: .manual).map(\.readingOrderPosition)
        XCTAssertEqual(first, second)
    }

    func test_override_winsOverEngineAndSurvivesRecompute() {
        for n in 1...5 { insertComic(series: "Flash", issue: "\(n)", title: "Flash #\(n)") }
        insertComic(series: "Flash", issue: "1", title: "Flash Annual #1")
        db.recomputeReadingOrder()

        let comics = db.allComics(series: "Flash", sortOrder: .manual)
        let annual = comics.first { $0.title.contains("Annual") }!
        let issue3 = comics.first { $0.title == "Flash #3" }!

        // Manually pin the annual to sit exactly at issue #3's position.
        db.setReadingOrderOverride(comicId: annual.id, position: issue3.readingOrderPosition! - 1)

        // Simulate a rescan — recomputeReadingOrder() runs again, but the override must win.
        db.recomputeReadingOrder()
        let afterRescan = db.allComics(series: "Flash", sortOrder: .manual)
        let annualAfter = afterRescan.first { $0.id == annual.id }!
        XCTAssertEqual(annualAfter.readingOrderPosition, issue3.readingOrderPosition! - 1)
        XCTAssertEqual(annualAfter.readingOrderConfidence, 100)
    }

    func test_clearOverride_letsEngineRecomputeAgain() {
        for n in 1...5 { insertComic(series: "GreenLantern", issue: "\(n)", title: "GL #\(n)") }
        insertComic(series: "GreenLantern", issue: "1", title: "GL Annual #1")
        db.recomputeReadingOrder()
        let annual = db.allComics(series: "GreenLantern", sortOrder: .manual).first { $0.title.contains("Annual") }!

        db.setReadingOrderOverride(comicId: annual.id, position: 999)
        db.recomputeReadingOrder()
        XCTAssertEqual(db.allComics(series: "GreenLantern", sortOrder: .manual).first { $0.id == annual.id }?.readingOrderPosition, 999)

        db.clearReadingOrderOverride(comicId: annual.id)
        db.recomputeReadingOrder()
        let afterClear = db.allComics(series: "GreenLantern", sortOrder: .manual).first { $0.id == annual.id }
        XCTAssertNotEqual(afterClear?.readingOrderPosition, 999)
    }

    func test_reorderComics_writesDurableOverride() {
        for n in 1...5 { insertComic(series: "Aquaman", issue: "\(n)", title: "Aquaman #\(n)") }
        let comics = db.allComics(series: "Aquaman", sortOrder: .manual)
        let reversed = comics.reversed().map(\.id)
        db.reorderComics(orderedIds: Array(reversed))

        // Simulate a rescan afterward — the drag must survive it.
        db.recomputeReadingOrder()
        let after = db.allComics(series: "Aquaman", sortOrder: .manual)
        XCTAssertEqual(after.map(\.id), Array(reversed))
    }
}
