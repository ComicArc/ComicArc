import XCTest
import SQLite3
@testable import ComicArc

final class ReadingOrderEngineTests: XCTestCase {

    func test_classify_regularIssue() {
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: "12", title: "Batman #12", series: "Batman"), .regular)
    }

    func test_comicType_rawValueRoundTrips() {
        for type in [ComicType.regular, .annual, .oneShot, .special, .giantSize, .kingSize, .alpha,
                     .omega, .issueZero, .pointIssue, .directorsCut, .preview, .fcbd, .ashcan,
                     .holidaySpecial, .tradePaperback, .hardcover, .omnibus, .graphicNovel, .compendium] {
            XCTAssertEqual(ComicType(rawValue: type.rawValue), type, "rawValue round-trip failed for \(type)")
        }
    }

    func test_classify_annual() {
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: "1", title: "Batman Annual #1", series: "Batman"), .annual)
    }

    func test_classify_oneShot() {
        XCTAssertEqual(ReadingOrderEngine.classify(issueNumber: nil, title: "Batman: Full Circle One-Shot", series: "Batman"), .oneShot)
    }

    func test_classify_giantSizeDoesNotOverrideAnnual() {

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
            input(2, num: 13, title: "#13"),
            input(3, type: .annual, year: 2005, month: 8, title: "Annual #1"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)

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

        let inputs = [
            input(1, group: "Marvel:ASM", num: 12, arc: "Rebirth", title: "ASM #12"),
            input(2, group: "DC:Flash", num: 5, arc: "Rebirth", title: "Flash #5"),
            input(3, group: "DC:Flash", num: 6, title: "Flash #6"),
            input(4, group: "DC:Flash", type: .special, arc: "Rebirth", title: "Flash Special"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)

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

        XCTAssertLessThan(results[101]!.position, results[102]!.position)

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

        XCTAssertGreaterThan(results[2]!.position, results[1]!.position)
        XCTAssertLessThan(results[2]!.position, results[3]!.position)
    }
}

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
                              title: String, year: Int? = nil, month: Int? = nil,
                              comicInfoIssueNumber: String? = nil, volume: String? = nil) {
        db.batchInsert([DatabaseManager.ComicInsert(
            title: title, filePath: "/tmp/\(UUID().uuidString).cbz", publisher: publisher,
            character: nil, series: series, issueNumber: issue, pageCount: 20,
            writer: nil, penciller: nil, year: year, storyArc: nil, languageIso: nil, fileHash: nil,
            coverMonth: month, comicInfoIssueNumber: comicInfoIssueNumber, volume: volume
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

        db.setReadingOrderOverride(comicId: annual.id, position: issue3.readingOrderPosition! - 1)

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

        db.recomputeReadingOrder()
        let after = db.allComics(series: "Aquaman", sortOrder: .manual)
        XCTAssertEqual(after.map(\.id), Array(reversed))
    }

    func test_mode_filename_fallsBackToLegacyPosition() {
        for n in 1...3 { insertComic(series: "Nightwing", issue: "\(n)", title: "Nightwing #\(n)") }
        insertComic(series: "Nightwing", issue: "1", title: "Nightwing Annual #1")
        db.recomputeReadingOrder(mode: .intelligent)
        XCTAssertTrue(db.allComics(series: "Nightwing", sortOrder: .manual).allSatisfy { $0.readingOrderPosition != nil })

        db.recomputeReadingOrder(mode: .filename)
        let comics = db.allComics(series: "Nightwing", sortOrder: .manual)

        XCTAssertTrue(comics.allSatisfy { $0.readingOrderPosition == nil })
    }

    func test_mode_legacyNumber_ordersByParsedIssueNumberOnly() {
        insertComic(series: "Shazam", issue: "3", title: "Shazam #3")
        insertComic(series: "Shazam", issue: "1", title: "Shazam #1")
        insertComic(series: "Shazam", issue: "2", title: "Shazam #2")
        db.recomputeReadingOrder(mode: .legacyNumber)
        let ordered = db.allComics(series: "Shazam", sortOrder: .manual).sorted { $0.readingOrderPosition! < $1.readingOrderPosition! }
        XCTAssertEqual(ordered.map(\.issueNumber), ["1", "2", "3"])
    }

    func test_mode_publicationDate_ordersByDateNotNumber() {
        insertComic(series: "Hawkeye", issue: "5", title: "Hawkeye #5", year: 2020, month: 1)
        insertComic(series: "Hawkeye", issue: "1", title: "Hawkeye #1", year: 2021, month: 1)
        db.recomputeReadingOrder(mode: .publicationDate)
        let ordered = db.allComics(series: "Hawkeye", sortOrder: .manual).sorted { $0.readingOrderPosition! < $1.readingOrderPosition! }

        XCTAssertEqual(ordered.first?.issueNumber, "5")
    }

    func test_mode_comicInfoOrder_usesEmbeddedNumberNotFilename() {

        insertComic(series: "Moonknight", issue: "10", title: "A", comicInfoIssueNumber: "2")
        insertComic(series: "Moonknight", issue: "20", title: "B", comicInfoIssueNumber: "1")
        db.recomputeReadingOrder(mode: .comicInfoOrder)
        let ordered = db.allComics(series: "Moonknight", sortOrder: .manual).sorted { $0.readingOrderPosition! < $1.readingOrderPosition! }
        XCTAssertEqual(ordered.map(\.title), ["B", "A"])
    }

    func test_recomputeReadingOrder_affectedGroupKeysLeavesOtherSeriesUntouched() {
        for n in 1...3 { insertComic(series: "Thor", issue: "\(n)", title: "Thor #\(n)") }
        for n in 1...3 { insertComic(series: "Loki", issue: "\(n)", title: "Loki #\(n)") }
        db.recomputeReadingOrder()
        let thorBefore = db.allComics(series: "Thor", sortOrder: .manual).map(\.readingOrderPosition)
        let lokiBefore = db.allComics(series: "Loki", sortOrder: .manual).map(\.readingOrderPosition)

        db.recomputeReadingOrder(mode: .legacyNumber, affectedGroupKeys: ["Marvel:Thor"])

        let thorAfter = db.allComics(series: "Thor", sortOrder: .manual).map(\.readingOrderPosition)
        let lokiAfter = db.allComics(series: "Loki", sortOrder: .manual).map(\.readingOrderPosition)
        XCTAssertNotEqual(thorBefore, thorAfter)
        XCTAssertEqual(lokiBefore, lokiAfter)
    }

    func test_seriesLink_childSortsAfterParent() {
        for n in 1...3 { insertComic(series: "Amazing Spider-Man", issue: "\(n)", title: "ASM #\(n)") }
        for n in 1...3 { insertComic(series: "Superior Spider-Man", issue: "\(n)", title: "SSM #\(n)") }
        db.recomputeReadingOrder()

        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "Amazing Spider-Man",
                          childPublisher: "Marvel", childSeries: "Superior Spider-Man")
        db.recomputeReadingOrder()

        let asmMax = db.allComics(series: "Amazing Spider-Man", sortOrder: .manual).compactMap(\.readingOrderPosition).max()!
        let ssmMin = db.allComics(series: "Superior Spider-Man", sortOrder: .manual).compactMap(\.readingOrderPosition).min()!
        XCTAssertGreaterThan(ssmMin, asmMax)
    }

    func test_seriesLink_threeHopChain() {
        insertComic(series: "A", issue: "1", title: "A #1")
        insertComic(series: "B", issue: "1", title: "B #1")
        insertComic(series: "C", issue: "1", title: "C #1")
        db.recomputeReadingOrder()

        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "A", childPublisher: "Marvel", childSeries: "B")
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "B", childPublisher: "Marvel", childSeries: "C")
        db.recomputeReadingOrder()

        let aPos = db.allComics(series: "A", sortOrder: .manual).first!.readingOrderPosition!
        let bPos = db.allComics(series: "B", sortOrder: .manual).first!.readingOrderPosition!
        let cPos = db.allComics(series: "C", sortOrder: .manual).first!.readingOrderPosition!
        XCTAssertLessThan(aPos, bPos)
        XCTAssertLessThan(bPos, cPos)
    }

    func test_seriesLink_unlinkRestoresIndependentOrder() {
        for n in 1...3 { insertComic(series: "X", issue: "\(n)", title: "X #\(n)") }
        for n in 1...3 { insertComic(series: "Y", issue: "\(n)", title: "Y #\(n)") }
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "X", childPublisher: "Marvel", childSeries: "Y")
        db.recomputeReadingOrder()
        XCTAssertEqual(db.seriesLinks().count, 1)

        db.removeSeriesLink(childPublisher: "Marvel", childSeries: "Y")
        db.recomputeReadingOrder()
        XCTAssertEqual(db.seriesLinks().count, 0)

    }

    func test_addSeriesLink_rejectsSecondParentForSameChild() {
        insertComic(series: "P1", issue: "1", title: "P1 #1")
        insertComic(series: "P2", issue: "1", title: "P2 #1")
        insertComic(series: "Kid", issue: "1", title: "Kid #1")
        XCTAssertTrue(db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "P1", childPublisher: "Marvel", childSeries: "Kid"))
        XCTAssertFalse(db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "P2", childPublisher: "Marvel", childSeries: "Kid"))
        XCTAssertEqual(db.seriesLinks().count, 1)
    }

    func test_seriesWithMultipleFirstIssues_detectsCollision() {
        insertComic(series: "Relaunch", issue: "1", title: "Relaunch (2010) #1")
        insertComic(series: "Relaunch", issue: "1", title: "Relaunch (2020) #1")
        let hits = db.seriesWithMultipleFirstIssues()
        XCTAssertTrue(hits.contains { $0.series == "Relaunch" && $0.count == 2 })
    }

    func test_seriesWithMultipleFirstIssues_excludesAnnuals() {
        insertComic(series: "Robin", issue: "1", title: "Robin #1")
        insertComic(series: "Robin", issue: "1", title: "Robin Annual #1")
        let hits = db.seriesWithMultipleFirstIssues()
        XCTAssertFalse(hits.contains { $0.series == "Robin" })
    }

    func test_seriesWithMultipleFirstIssues_stillDetectsRealCollisionAlongsideAnnual() {
        insertComic(series: "Robin", issue: "1", title: "Robin #1")
        insertComic(series: "Robin", issue: "1", title: "Robin #1 (2nd Printing)")
        insertComic(series: "Robin", issue: "1", title: "Robin Annual #1")
        let hits = db.seriesWithMultipleFirstIssues()
        XCTAssertTrue(hits.contains { $0.series == "Robin" && $0.count == 2 })
    }

    // MARK: - duplicateGroups()

    func test_duplicateGroups_flagsSameTypeCollision() {
        insertComic(series: "Robin", issue: "1", title: "Robin #1")
        insertComic(series: "Robin", issue: "1", title: "Robin #1 (2nd Printing)")
        let groups = db.duplicateGroups()
        XCTAssertTrue(groups.contains { $0.count == 2 && $0.allSatisfy { $0.series == "Robin" } })
    }

    func test_duplicateGroups_doesNotFlagAnnualAgainstRegularIssue() {
        insertComic(series: "Robin", issue: "1", title: "Robin #1")
        insertComic(series: "Robin", issue: "1", title: "Robin Annual #1")
        let groups = db.duplicateGroups()
        XCTAssertTrue(groups.isEmpty, "Robin #1 and Robin Annual #1 must never be flagged as duplicates")
    }

    func test_duplicateGroups_doesNotFlagAnnualAgainstRegularIssue_ASM() {
        insertComic(series: "ASM", issue: "18", title: "The Amazing Spider-Man #18")
        insertComic(series: "ASM", issue: "18", title: "The Amazing Spider-Man Annual #18")
        let groups = db.duplicateGroups()
        XCTAssertTrue(groups.isEmpty, "ASM #18 and ASM Annual #18 must never be flagged as duplicates")
    }

    func test_duplicateGroups_doesNotFlagAcrossDifferentYears() {
        insertComic(series: "Legacy", issue: "1", title: "Legacy #1", year: 1990)
        insertComic(series: "Legacy", issue: "1", title: "Legacy #1", year: 2020)
        let groups = db.duplicateGroups()
        XCTAssertTrue(groups.isEmpty, "different-year #1s from different runs should not be flagged")
    }

    func test_duplicateGroups_toleratesOneYearSlop() {
        insertComic(series: "Legacy", issue: "1", title: "Legacy #1", year: 1990)
        insertComic(series: "Legacy", issue: "1", title: "Legacy #1", year: 1991)
        let groups = db.duplicateGroups()
        XCTAssertEqual(groups.count, 1, "cover-date vs on-sale-date slop of 1 year should still be treated as the same run")
    }

    func test_duplicateGroups_doesNotFlagAcrossDifferentVolumes() {
        insertComic(series: "Legacy", issue: "1", title: "Legacy #1", volume: "1963")
        insertComic(series: "Legacy", issue: "1", title: "Legacy #1", volume: "2014")
        let groups = db.duplicateGroups()
        XCTAssertTrue(groups.isEmpty, "different explicit Volume values should not be flagged as duplicates")
    }

    func test_libraryHealthAnalyzer_reportIsEmptyForCleanLibrary() {
        for n in 1...5 { insertComic(series: "Clean", issue: "\(n)", title: "Clean #\(n)", comicInfoIssueNumber: "\(n)") }
        db.recomputeReadingOrder()
        let report = LibraryHealthAnalyzer.analyze(db: db)
        XCTAssertEqual(report.multipleFirstIssues.count, 0)
        XCTAssertTrue(report.isEmpty)
    }

    func test_libraryHealthAnalyzer_reportFlagsRealIssues() {
        insertComic(series: "Messy", issue: "1", title: "Messy (v1) #1")
        insertComic(series: "Messy", issue: "1", title: "Messy (v2) #1")
        let report = LibraryHealthAnalyzer.analyze(db: db)
        XCTAssertFalse(report.isEmpty)
        XCTAssertTrue(report.multipleFirstIssues.contains { $0.series == "Messy" })
    }

    // MARK: - Series link auto-population (real-world regression coverage)

    private func buildBondFixture(at path: String) {
        var fdb: OpaquePointer?
        sqlite3_open(path, &fdb)
        defer { sqlite3_close(fdb) }
        let sql = """
        CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT, sort_name TEXT,
            year_began INTEGER, year_ended INTEGER, publisher_id INTEGER,
            issue_count INTEGER, deleted INTEGER, norm_name TEXT, initials TEXT);
        CREATE TABLE issue (id INTEGER PRIMARY KEY, series_id INTEGER, number TEXT,
            key_date TEXT, sort_code INTEGER, title TEXT, variant_of_id INTEGER, deleted INTEGER);
        CREATE TABLE publisher (id INTEGER PRIMARY KEY, name TEXT, deleted INTEGER);
        CREATE TABLE series_bond (id INTEGER PRIMARY KEY, origin_id INTEGER, target_id INTEGER,
            origin_issue_id INTEGER, target_issue_id INTEGER, bond_type_id INTEGER);
        CREATE TABLE series_bond_type (id INTEGER PRIMARY KEY, name TEXT);

        INSERT INTO publisher VALUES (1, 'Marvel', 0);
        INSERT INTO series VALUES (100, 'Tales of Suspense', 'Tales of Suspense', 1959, 1968, 1, 99, 0, 'tales of suspense', 'TOS');
        INSERT INTO series VALUES (101, 'Captain America', 'Captain America', 1968, 1996, 1, 300, 0, 'captain america', 'CA');
        INSERT INTO series_bond_type VALUES (2, 'major_name_numbering_continues');
        INSERT INTO series_bond VALUES (1, 100, 101, NULL, NULL, 2);
        """
        var errmsg: UnsafeMutablePointer<Int8>?
        sqlite3_exec(fdb, sql, nil, nil, &errmsg)
        if let errmsg { XCTFail("bond fixture build failed: \(String(cString: errmsg))") }
    }

    func test_autoPopulateSeriesLinksFromGCD_resolvesAbbreviatedLocalFolders() {
        // Real-world regression: a local library organizes these under abbreviated folder
        // names ("TOS (Modern)", "Cap America") rather than GCD's full official names — the
        // auto-linker must use the same abbreviation-aware matching lookupIssue does, not a
        // bare exact-normalized-name comparison (which would silently link nothing, exactly
        // the bug found by testing this against a real library).
        insertComic(series: "TOS (Modern)", issue: "99", title: "TOS (Modern) #99")
        insertComic(series: "Captain America", issue: "100", title: "Captain America #100")

        let bondPath = NSTemporaryDirectory() + "bond-fixture-\(UUID().uuidString).sqlite"
        buildBondFixture(at: bondPath)
        defer { try? FileManager.default.removeItem(atPath: bondPath) }
        let bondStore = OfflineMetadataStore(path: bondPath)

        db.autoPopulateSeriesLinksFromGCD(store: bondStore)

        let links = db.seriesLinks()
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.parentSeries, "TOS (Modern)")
        XCTAssertEqual(links.first?.childSeries, "Captain America")
        XCTAssertEqual(links.first?.source, "gcd")
    }

    func test_autoPopulateSeriesLinksFromGCD_doesNotOverwriteManualLink() {
        insertComic(series: "TOS (Modern)", issue: "99", title: "TOS (Modern) #99")
        insertComic(series: "Captain America", issue: "100", title: "Captain America #100")
        insertComic(series: "SomeOtherParent", issue: "1", title: "SomeOtherParent #1")
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "SomeOtherParent",
                          childPublisher: "Marvel", childSeries: "Captain America", source: "manual")

        let bondPath = NSTemporaryDirectory() + "bond-fixture-\(UUID().uuidString).sqlite"
        buildBondFixture(at: bondPath)
        defer { try? FileManager.default.removeItem(atPath: bondPath) }
        let bondStore = OfflineMetadataStore(path: bondPath)

        db.autoPopulateSeriesLinksFromGCD(store: bondStore)

        let links = db.seriesLinks()
        XCTAssertEqual(links.count, 1) // still just the manual one, not replaced/duplicated
        XCTAssertEqual(links.first?.parentSeries, "SomeOtherParent")
        XCTAssertEqual(links.first?.source, "manual")
    }

    // MARK: - Legacy numbering / filename-mode safety guarantees

    func test_legacyNumber_alwaysWinsForMainlineIssues() {
        // A dated mainline issue must still sort strictly by its legacy number, never by date,
        // even when its cover date would suggest a different order than its issue number.
        insertComic(series: "Chrono", issue: "1", title: "Chrono #1", year: 2020, month: 6)
        insertComic(series: "Chrono", issue: "2", title: "Chrono #2", year: 2020, month: 1) // earlier date, higher number
        db.recomputeReadingOrder(mode: .intelligent)
        let comics = db.allComics(series: "Chrono", sortOrder: .manual)
        let issue1 = comics.first { $0.title == "Chrono #1" }!
        let issue2 = comics.first { $0.title == "Chrono #2" }!
        XCTAssertLessThan(issue1.readingOrderPosition!, issue2.readingOrderPosition!)
        XCTAssertEqual(issue1.readingOrderConfidence, 100)
        XCTAssertEqual(issue2.readingOrderConfidence, 100)
    }

    func test_filenameMode_roundTripsExactlyToOriginalPosition() {
        for n in 1...5 { insertComic(series: "Roundtrip", issue: "\(n)", title: "Roundtrip #\(n)") }
        insertComic(series: "Roundtrip", issue: "1", title: "Roundtrip Annual #1")
        let original = db.allComics(series: "Roundtrip", sortOrder: .manual).map(\.position)

        db.recomputeReadingOrder(mode: .intelligent)
        db.recomputeReadingOrder(mode: .legacyNumber)
        db.recomputeReadingOrder(mode: .publicationDate)
        db.recomputeReadingOrder(mode: .filename)

        let afterRoundTrip = db.allComics(series: "Roundtrip", sortOrder: .manual).map(\.position)
        XCTAssertEqual(original, afterRoundTrip, "switching modes must never mutate the underlying filename/legacy position")
    }

    // MARK: - Reading Order Manager (autoPlacedSpecialIssues)

    func test_autoPlacedSpecialIssues_excludesManualAndAlwaysLastBand() {
        for n in 1...20 { insertComic(series: "Cosmic", issue: "\(n)", title: "Cosmic #\(n)", year: 2000, month: (n % 12) + 1) }
        insertComic(series: "Cosmic", issue: "1", title: "Cosmic Annual #1", year: 2000, month: 6) // tier1/2, confidence 60-100
        insertComic(series: "Solo", issue: "1", title: "Solo Special #1") // no mainline siblings -> always-last band, confidence 0
        db.recomputeReadingOrder(mode: .intelligent)

        let suggestions = db.autoPlacedSpecialIssues()
        XCTAssertTrue(suggestions.contains { $0.title == "Cosmic Annual #1" })
        XCTAssertFalse(suggestions.contains { $0.title == "Solo Special #1" }, "confidence-0 always-last placements aren't real suggestions to review")
        XCTAssertTrue(suggestions.allSatisfy { ($0.readingOrderConfidence ?? 0) >= 1 && ($0.readingOrderConfidence ?? 0) <= 99 })
    }

    func test_autoPlacedSpecialIssues_excludesManuallyOverriddenIssues() {
        for n in 1...20 { insertComic(series: "Cosmic", issue: "\(n)", title: "Cosmic #\(n)", year: 2000, month: (n % 12) + 1) }
        insertComic(series: "Cosmic", issue: "1", title: "Cosmic Annual #1", year: 2000, month: 6)
        db.recomputeReadingOrder(mode: .intelligent)
        let annual = db.allComics(series: "Cosmic", sortOrder: .manual).first { $0.title.contains("Annual") }!

        db.setReadingOrderOverride(comicId: annual.id, position: annual.position)
        db.recomputeReadingOrder(mode: .intelligent)

        let suggestions = db.autoPlacedSpecialIssues()
        XCTAssertFalse(suggestions.contains { $0.id == annual.id }, "a manually-confirmed placement (confidence 100) shouldn't still show up as a pending suggestion")
    }
}
