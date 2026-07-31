import Testing
import Foundation
import SQLite3
@testable import ComicArc

struct ReadingOrderEngineTests {

    @Test func classifyRegularIssue() {
        #expect(ReadingOrderEngine.classify(issueNumber: "12", title: "Batman #12", series: "Batman") == .regular)
    }

    @Test("rawValue round-trips for every ComicType", arguments: [
        ComicType.regular, .annual, .oneShot, .special, .giantSize, .kingSize, .alpha,
        .omega, .issueZero, .pointIssue, .directorsCut, .preview, .fcbd, .ashcan,
        .holidaySpecial, .tradePaperback, .hardcover, .omnibus, .graphicNovel, .compendium,
    ])
    func comicTypeRawValueRoundTrips(type: ComicType) {
        #expect(ComicType(rawValue: type.rawValue) == type)
    }

    @Test func classifyAnnual() {
        #expect(ReadingOrderEngine.classify(issueNumber: "1", title: "Batman Annual #1", series: "Batman") == .annual)
    }

    @Test func classifyOneShot() {
        #expect(ReadingOrderEngine.classify(issueNumber: nil, title: "Batman: Full Circle One-Shot", series: "Batman") == .oneShot)
    }

    @Test func classifyGiantSizeDoesNotOverrideAnnual() {
        #expect(ReadingOrderEngine.classify(issueNumber: "1", title: "X-Men Giant-Size Annual #1", series: "X-Men") == .annual)
    }

    @Test("A series name containing a type keyword as an ordinary word must not misclassify every issue in it -- only the comic's own title/issue-number field, where a real special names itself as such, is searched")
    func classifySeriesNamedSpecialDoesNotMisclassify() {
        #expect(ReadingOrderEngine.classify(issueNumber: "12", title: "Chapter Twelve", series: "Extra Special Adventures") == .regular)
    }

    @Test("A genuine special that names itself in its own title still classifies correctly")
    func classifyTitleWithSpecialStillMatches() {
        #expect(ReadingOrderEngine.classify(issueNumber: nil, title: "A Very Special Christmas Special", series: "Batman") == .special)
    }

    @Test func classifyAlphaOmega() {
        #expect(ReadingOrderEngine.classify(issueNumber: "Alpha", title: "Infinity Alpha", series: "Infinity") == .alpha)
        #expect(ReadingOrderEngine.classify(issueNumber: "Omega", title: "Infinity Omega", series: "Infinity") == .omega)
    }

    @Test func classifyIssueZero() {
        #expect(ReadingOrderEngine.classify(issueNumber: "0", title: "Batman #0", series: "Batman") == .issueZero)
    }

    @Test func classifyPointIssue() {
        #expect(ReadingOrderEngine.classify(issueNumber: "12.1", title: "Batman #12.1", series: "Batman") == .pointIssue)
    }

    @Test func classifyFcbdAndAshcan() {
        #expect(ReadingOrderEngine.classify(issueNumber: nil, title: "Batman FCBD Special Edition", series: "Batman") == .fcbd)
        #expect(ReadingOrderEngine.classify(issueNumber: nil, title: "Batman Ashcan Edition", series: "Batman") == .ashcan)
    }

    @Test func classifyFormatOnlyTypesDoNotNeedPlacement() {
        #expect(ReadingOrderEngine.classify(issueNumber: nil, title: "Batman Vol. 1 TPB", series: "Batman").needsPlacement == false)
        #expect(ReadingOrderEngine.classify(issueNumber: nil, title: "Batman Omnibus", series: "Batman").needsPlacement == false)
    }

    @Test func classifySpecialTypesNeedPlacement() {
        #expect(ComicType.annual.needsPlacement)
        #expect(ComicType.oneShot.needsPlacement)
        #expect(ComicType.regular.needsPlacement == false)
    }

    @Test func parseLegacyNumberInteger() {
        #expect(ReadingOrderEngine.parseLegacyNumber("700") == 700)
    }

    @Test func parseLegacyNumberDecimal() {
        #expect(ReadingOrderEngine.parseLegacyNumber("12.1") == 12.1)
    }

    @Test func parseLegacyNumberNonNumericReturnsNil() {
        #expect(ReadingOrderEngine.parseLegacyNumber("Alpha") == nil)
        #expect(ReadingOrderEngine.parseLegacyNumber(nil) == nil)
        #expect(ReadingOrderEngine.parseLegacyNumber("") == nil)
    }

    private func input(_ id: Int64, group: String = "Marvel:ASM", num: Double? = nil,
                        type: ComicType = .regular, year: Int? = nil, month: Int? = nil, day: Int? = nil,
                        arc: String? = nil, title: String = "") -> ReadingOrderEngine.ReadingOrderInput {
        .init(id: id, groupKey: group, legacyNumber: num, comicType: type,
              year: year, month: month, day: day, storyArc: arc, title: title)
    }

    @Test func tier1FullDateInterpolation() throws {
        let inputs = [
            input(1, num: 12, year: 2005, month: 6, title: "#12"),
            input(2, num: 13, year: 2005, month: 9, title: "#13"),
            input(3, type: .annual, year: 2005, month: 8, title: "Annual #1"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)
        #expect(results[3]?.confidence == 100)
        let annual = try #require(results[3])
        #expect(try annual.position > #require(results[1]).position)
        #expect(try annual.position < #require(results[2]).position)
    }

    @Test func tier2SingleDateAnchor() throws {
        let inputs = [
            input(1, num: 12, year: 2005, month: 6, title: "#12"),
            input(2, num: 13, title: "#13"),
            input(3, type: .annual, year: 2005, month: 8, title: "Annual #1"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)

        #expect(results[3]?.confidence == 85)
        let annual = try #require(results[3])
        #expect(try annual.position > #require(results[1]).position)
    }

    @Test func tier3StoryArcAdjacency() throws {
        let inputs = [
            input(1, num: 12, arc: "No Man's Land", title: "#12"),
            input(2, num: 13, title: "#13"),
            input(3, type: .special, arc: "No Man's Land", title: "Special #1"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)
        #expect(results[3]?.confidence == 85)
        #expect(try results[3]?.position == #require(results[1]).position + 1)
    }

    @Test func tier3StoryArcDoesNotMatchAcrossGroups() throws {
        let inputs = [
            input(1, group: "Marvel:ASM", num: 12, arc: "Rebirth", title: "ASM #12"),
            input(2, group: "DC:Flash", num: 5, arc: "Rebirth", title: "Flash #5"),
            input(3, group: "DC:Flash", num: 6, title: "Flash #6"),
            input(4, group: "DC:Flash", type: .special, arc: "Rebirth", title: "Flash Special"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)

        #expect(try results[4]?.position == #require(results[2]).position + 1)
    }

    @Test func tier4ProportionalSpreadWhenNoOtherSignal() throws {
        let inputs = (1...20).map { input(Int64($0), num: Double($0), title: "#\($0)") } + [
            input(101, num: 1, type: .annual, title: "Annual #1"),
            input(102, num: 2, type: .annual, title: "Annual #2"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)
        #expect(results[101]?.confidence == 60)
        #expect(results[102]?.confidence == 60)

        #expect(try #require(results[101]).position < #require(results[102]).position)

        #expect(try #require(results[102]).position < #require(results[20]).position)
    }

    @Test func tier5AlwaysLastWhenNoMainlineSiblings() throws {
        let inputs = [
            input(1, group: "Solo:Annuals", num: 1, type: .annual, title: "Annual #1"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)
        #expect(results[1]?.confidence == 0)
        #expect(try #require(results[1]).position >= ReadingOrderEngine.alwaysLastBand)
    }

    @Test func tier4DeterministicAcrossRepeatedRuns() throws {
        let inputs = (1...10).map { input(Int64($0), num: Double($0), title: "#\($0)") } + [
            input(101, num: 3, type: .annual, title: "Annual #3"),
            input(102, num: 1, type: .annual, title: "Annual #1"),
            input(103, num: 2, type: .annual, title: "Annual #2"),
        ]
        let first  = ReadingOrderEngine.computeSeriesPositions(inputs)
        let second = ReadingOrderEngine.computeSeriesPositions(inputs)
        for id in [101, 102, 103] {
            #expect(first[Int64(id)]?.position == second[Int64(id)]?.position)
        }

        #expect(try #require(first[102]).position < #require(first[103]).position)
        #expect(try #require(first[103]).position < #require(first[101]).position)
    }

    @Test func decimalPointIssueGetsOwnSlotBetweenNeighbors() throws {
        let inputs = [
            input(1, num: 12, title: "#12"),
            input(2, num: 12.1, type: .pointIssue, title: "#12.1"),
            input(3, num: 13, title: "#13"),
        ]
        let results = ReadingOrderEngine.computeSeriesPositions(inputs)

        #expect(try #require(results[2]).position > #require(results[1]).position)
        #expect(try #require(results[2]).position < #require(results[3]).position)
    }
}

final class ReadingOrderEngineDatabaseTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "ReadingOrderEngineTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    @discardableResult
    private func insertComic(series: String, publisher: String = "Marvel", issue: String?,
                              title: String, year: Int? = nil, month: Int? = nil, day: Int? = nil,
                              comicInfoIssueNumber: String? = nil, volume: String? = nil,
                              format: String? = nil, fileHash: String? = nil,
                              alternateNumber: String? = nil, hasComicInfo: Bool? = nil) throws -> Int64 {
        try insertTestComic(into: db, series: series, publisher: publisher, issue: issue, title: title,
                            year: year, month: month, day: day, fileHash: fileHash,
                            comicInfoIssueNumber: comicInfoIssueNumber, volume: volume, format: format,
                            alternateNumber: alternateNumber, hasComicInfo: hasComicInfo)
    }

    @Test func recomputeReadingOrderMovesAnnualOutOfAlwaysLastBand() throws {
        for n in 1...20 { try insertComic(series: "ASM", issue: "\(n)", title: "ASM #\(n)") }
        try insertComic(series: "ASM", issue: "1", title: "ASM Annual #1")
        db.recomputeReadingOrder()

        let comics = db.allComics(series: "ASM", sortOrder: .manual)
        let annual = try #require(comics.first { $0.title.contains("Annual") })
        #expect(annual.readingOrderPosition != nil)
        #expect(annual.readingOrderConfidence != nil)

        #expect(annual.readingOrderConfidence == 60)
    }

    @Test func recomputeReadingOrderIsIdempotent() throws {
        for n in 1...5 { try insertComic(series: "Batman", issue: "\(n)", title: "Batman #\(n)") }
        try insertComic(series: "Batman", issue: "1", title: "Batman Annual #1")
        db.recomputeReadingOrder()
        let first = db.allComics(series: "Batman", sortOrder: .manual).map(\.readingOrderPosition)
        db.recomputeReadingOrder()
        let second = db.allComics(series: "Batman", sortOrder: .manual).map(\.readingOrderPosition)
        #expect(first == second)
    }

    @Test func overrideWinsOverEngineAndSurvivesRecompute() throws {
        for n in 1...5 { try insertComic(series: "Flash", issue: "\(n)", title: "Flash #\(n)") }
        try insertComic(series: "Flash", issue: "1", title: "Flash Annual #1")
        db.recomputeReadingOrder()

        let comics = db.allComics(series: "Flash", sortOrder: .manual)
        let annual = try #require(comics.first { $0.title.contains("Annual") })
        let issue3 = try #require(comics.first { $0.title == "Flash #3" })
        let issue3Position = try #require(issue3.readingOrderPosition)

        db.setReadingOrderOverride(comicId: annual.id, position: issue3Position - 1)

        db.recomputeReadingOrder()
        let afterRescan = db.allComics(series: "Flash", sortOrder: .manual)
        let annualAfter = try #require(afterRescan.first { $0.id == annual.id })
        #expect(annualAfter.readingOrderPosition == issue3Position - 1)
        #expect(annualAfter.readingOrderConfidence == 100)
    }

    @Test func reorderComicsWritesDurableOverride() throws {
        for n in 1...5 { try insertComic(series: "Aquaman", issue: "\(n)", title: "Aquaman #\(n)") }
        let comics = db.allComics(series: "Aquaman", sortOrder: .manual)
        let reversed = comics.reversed().map(\.id)
        db.reorderComics(orderedIds: Array(reversed))

        db.recomputeReadingOrder()
        let after = db.allComics(series: "Aquaman", sortOrder: .manual)
        #expect(after.map(\.id) == Array(reversed))
    }

    @Test func modeFilenameFallsBackToLegacyPosition() throws {
        for n in 1...3 { try insertComic(series: "Nightwing", issue: "\(n)", title: "Nightwing #\(n)") }
        try insertComic(series: "Nightwing", issue: "1", title: "Nightwing Annual #1")
        db.recomputeReadingOrder(mode: .intelligent)
        #expect(db.allComics(series: "Nightwing", sortOrder: .manual).allSatisfy { $0.readingOrderPosition != nil })

        db.recomputeReadingOrder(mode: .filename)
        let comics = db.allComics(series: "Nightwing", sortOrder: .manual)

        #expect(comics.allSatisfy { $0.readingOrderPosition == nil })
    }

    @Test func modeLegacyNumberOrdersByParsedIssueNumberOnly() throws {
        try insertComic(series: "Shazam", issue: "3", title: "Shazam #3")
        try insertComic(series: "Shazam", issue: "1", title: "Shazam #1")
        try insertComic(series: "Shazam", issue: "2", title: "Shazam #2")
        db.recomputeReadingOrder(mode: .legacyNumber)
        let ordered = try db.allComics(series: "Shazam", sortOrder: .manual).sorted {
            try #require($0.readingOrderPosition) < #require($1.readingOrderPosition)
        }
        #expect(ordered.map(\.issueNumber) == ["1", "2", "3"])
    }

    @Test func modePublicationDateOrdersByDateNotNumber() throws {
        try insertComic(series: "Hawkeye", issue: "5", title: "Hawkeye #5", year: 2020, month: 1)
        try insertComic(series: "Hawkeye", issue: "1", title: "Hawkeye #1", year: 2021, month: 1)
        db.recomputeReadingOrder(mode: .publicationDate)
        let ordered = try db.allComics(series: "Hawkeye", sortOrder: .manual).sorted {
            try #require($0.readingOrderPosition) < #require($1.readingOrderPosition)
        }

        #expect(ordered.first?.issueNumber == "5")
    }

    @Test func modeComicInfoOrderUsesEmbeddedNumberNotFilename() throws {
        try insertComic(series: "Moonknight", issue: "10", title: "A", comicInfoIssueNumber: "2")
        try insertComic(series: "Moonknight", issue: "20", title: "B", comicInfoIssueNumber: "1")
        db.recomputeReadingOrder(mode: .comicInfoOrder)
        let ordered = try db.allComics(series: "Moonknight", sortOrder: .manual).sorted {
            try #require($0.readingOrderPosition) < #require($1.readingOrderPosition)
        }
        #expect(ordered.map(\.title) == ["B", "A"])
    }

    @Test func recomputeReadingOrderAffectedGroupKeysLeavesOtherSeriesUntouched() throws {
        for n in 1...3 { try insertComic(series: "Thor", issue: "\(n)", title: "Thor #\(n)") }
        for n in 1...3 { try insertComic(series: "Loki", issue: "\(n)", title: "Loki #\(n)") }
        db.recomputeReadingOrder()
        let thorBefore = db.allComics(series: "Thor", sortOrder: .manual).map(\.readingOrderPosition)
        let lokiBefore = db.allComics(series: "Loki", sortOrder: .manual).map(\.readingOrderPosition)

        db.recomputeReadingOrder(mode: .legacyNumber, affectedGroupKeys: ["Marvel:Thor"])

        let thorAfter = db.allComics(series: "Thor", sortOrder: .manual).map(\.readingOrderPosition)
        let lokiAfter = db.allComics(series: "Loki", sortOrder: .manual).map(\.readingOrderPosition)
        #expect(thorBefore != thorAfter)
        #expect(lokiBefore == lokiAfter)
    }

    @Test("Real bug: LibraryScanner computes affectedGroupKeys BEFORE recomputeGCDMatches runs, so for a freshly-scanned comic with no ComicInfo.xml <Volume> tag yet, that key is a bare \"publisher:series\" with no volume. If recomputeGCDMatches then backfills comics.volume (e.g. from the matched GCD series' own start year), the row's real composite groupKey gains a volume suffix the caller's stale key never had -- without expanding bare keys, recomputeReadingOrder(affectedGroupKeys:) would silently find zero matching rows and this comic's readingOrderPosition would never get set")
    func recomputeReadingOrderBareAffectedGroupKeyStillMatchesAfterVolumeGetsBackfilled() throws {
        try insertComic(series: "Newly Scanned", issue: "1", title: "Newly Scanned #1", volume: "2013")
        db.recomputeReadingOrder(affectedGroupKeys: ["Marvel:Newly Scanned"])
        let comic = try #require(db.allComics(series: "Newly Scanned", sortOrder: .manual).first)
        #expect(comic.readingOrderPosition != nil, "a bare publisher:series key must still resolve to a row whose real groupKey now includes a volume")
    }

    @Test func seriesLinkChildSortsAfterParent() throws {
        for n in 1...3 { try insertComic(series: "Amazing Spider-Man", issue: "\(n)", title: "ASM #\(n)") }
        for n in 1...3 { try insertComic(series: "Superior Spider-Man", issue: "\(n)", title: "SSM #\(n)") }
        db.recomputeReadingOrder()

        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "Amazing Spider-Man",
                          childPublisher: "Marvel", childSeries: "Superior Spider-Man")
        db.recomputeReadingOrder()

        let asmMax = try #require(db.allComics(series: "Amazing Spider-Man", sortOrder: .manual).compactMap(\.readingOrderPosition).max())
        let ssmMin = try #require(db.allComics(series: "Superior Spider-Man", sortOrder: .manual).compactMap(\.readingOrderPosition).min())
        #expect(ssmMin > asmMax)
    }

    @Test func seriesLinkThreeHopChain() throws {
        try insertComic(series: "A", issue: "1", title: "A #1")
        try insertComic(series: "B", issue: "1", title: "B #1")
        try insertComic(series: "C", issue: "1", title: "C #1")
        db.recomputeReadingOrder()

        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "A", childPublisher: "Marvel", childSeries: "B")
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "B", childPublisher: "Marvel", childSeries: "C")
        db.recomputeReadingOrder()

        let aComic = try #require(db.allComics(series: "A", sortOrder: .manual).first)
        let bComic = try #require(db.allComics(series: "B", sortOrder: .manual).first)
        let cComic = try #require(db.allComics(series: "C", sortOrder: .manual).first)
        let aPos = try #require(aComic.readingOrderPosition)
        let bPos = try #require(bComic.readingOrderPosition)
        let cPos = try #require(cComic.readingOrderPosition)
        #expect(aPos < bPos)
        #expect(bPos < cPos)
    }

    @Test func seriesLinkUnlinkRestoresIndependentOrder() throws {
        for n in 1...3 { try insertComic(series: "X", issue: "\(n)", title: "X #\(n)") }
        for n in 1...3 { try insertComic(series: "Y", issue: "\(n)", title: "Y #\(n)") }
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "X", childPublisher: "Marvel", childSeries: "Y")
        db.recomputeReadingOrder()
        #expect(db.seriesLinks().count == 1)

        db.removeSeriesLink(childPublisher: "Marvel", childSeries: "Y")
        db.recomputeReadingOrder()
        #expect(db.seriesLinks().count == 0)
    }

    @Test func addSeriesLinkRejectsSecondParentForSameChild() throws {
        try insertComic(series: "P1", issue: "1", title: "P1 #1")
        try insertComic(series: "P2", issue: "1", title: "P2 #1")
        try insertComic(series: "Kid", issue: "1", title: "Kid #1")
        #expect(db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "P1", childPublisher: "Marvel", childSeries: "Kid"))
        #expect(db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "P2", childPublisher: "Marvel", childSeries: "Kid") == false)
        #expect(db.seriesLinks().count == 1)
    }

    @Test func seriesWithMultipleFirstIssuesDetectsCollision() throws {
        try insertComic(series: "Relaunch", issue: "1", title: "Relaunch (2010) #1")
        try insertComic(series: "Relaunch", issue: "1", title: "Relaunch (2020) #1")
        let hits = db.seriesWithMultipleFirstIssues()
        #expect(hits.contains { $0.series == "Relaunch" && $0.count == 2 })
    }

    @Test func seriesWithMultipleFirstIssuesExcludesAnnuals() throws {
        try insertComic(series: "Robin", issue: "1", title: "Robin #1")
        try insertComic(series: "Robin", issue: "1", title: "Robin Annual #1")
        let hits = db.seriesWithMultipleFirstIssues()
        #expect(hits.contains { $0.series == "Robin" } == false)
    }

    @Test func seriesWithMultipleFirstIssuesStillDetectsRealCollisionAlongsideAnnual() throws {
        try insertComic(series: "Robin", issue: "1", title: "Robin #1")
        try insertComic(series: "Robin", issue: "1", title: "Robin #1 (2nd Printing)")
        try insertComic(series: "Robin", issue: "1", title: "Robin Annual #1")
        let hits = db.seriesWithMultipleFirstIssues()
        #expect(hits.contains { $0.series == "Robin" && $0.count == 2 })
    }

    @Test func duplicateGroupsFlagsSameTypeCollision() throws {
        try insertComic(series: "Robin", issue: "1", title: "Robin #1")
        try insertComic(series: "Robin", issue: "1", title: "Robin #1 (2nd Printing)")
        let groups = db.duplicateGroups()
        #expect(groups.contains { $0.count == 2 && $0.allSatisfy { $0.series == "Robin" } })
    }

    @Test func duplicateGroupsDoesNotFlagAnnualAgainstRegularIssue() throws {
        try insertComic(series: "Robin", issue: "1", title: "Robin #1")
        try insertComic(series: "Robin", issue: "1", title: "Robin Annual #1")
        let groups = db.duplicateGroups()
        #expect(groups.isEmpty, "Robin #1 and Robin Annual #1 must never be flagged as duplicates")
    }

    @Test func duplicateGroupsDoesNotFlagAnnualAgainstRegularIssueASM() throws {
        try insertComic(series: "ASM", issue: "18", title: "The Amazing Spider-Man #18")
        try insertComic(series: "ASM", issue: "18", title: "The Amazing Spider-Man Annual #18")
        let groups = db.duplicateGroups()
        #expect(groups.isEmpty, "ASM #18 and ASM Annual #18 must never be flagged as duplicates")
    }

    @Test func duplicateGroupsDoesNotFlagAcrossDifferentYears() throws {
        try insertComic(series: "Legacy", issue: "1", title: "Legacy #1", year: 1990)
        try insertComic(series: "Legacy", issue: "1", title: "Legacy #1", year: 2020)
        let groups = db.duplicateGroups()
        #expect(groups.isEmpty, "different-year #1s from different runs should not be flagged")
    }

    @Test func duplicateGroupsToleratesOneYearSlop() throws {
        try insertComic(series: "Legacy", issue: "1", title: "Legacy #1", year: 1990)
        try insertComic(series: "Legacy", issue: "1", title: "Legacy #1", year: 1991)
        let groups = db.duplicateGroups()
        #expect(groups.count == 1, "cover-date vs on-sale-date slop of 1 year should still be treated as the same run")
    }

    @Test func duplicateGroupsDoesNotFlagAcrossDifferentVolumes() throws {
        try insertComic(series: "Legacy", issue: "1", title: "Legacy #1", volume: "1963")
        try insertComic(series: "Legacy", issue: "1", title: "Legacy #1", volume: "2014")
        let groups = db.duplicateGroups()
        #expect(groups.isEmpty, "different explicit Volume values should not be flagged as duplicates")
    }

    @Test func libraryHealthAnalyzerReportIsEmptyForCleanLibrary() throws {
        for n in 1...5 { try insertComic(series: "Clean", issue: "\(n)", title: "Clean #\(n)", comicInfoIssueNumber: "\(n)") }
        db.recomputeReadingOrder()
        let report = LibraryHealthAnalyzer.analyze(db: db)
        #expect(report.multipleFirstIssues.count == 0)
        #expect(report.isEmpty)
    }

    @Test func libraryHealthAnalyzerReportFlagsRealIssues() throws {
        try insertComic(series: "Messy", issue: "1", title: "Messy (v1) #1")
        try insertComic(series: "Messy", issue: "1", title: "Messy (v2) #1")
        let report = LibraryHealthAnalyzer.analyze(db: db)
        #expect(report.isEmpty == false)
        #expect(report.multipleFirstIssues.contains { $0.series == "Messy" })
    }

    /// The GCD offline-metadata schema shared by every fake-GCD-database fixture in this file.
    /// Callers append their own INSERTs via `seedSQL`.
    private static let gcdSchemaDDL = """
    CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT, sort_name TEXT,
        year_began INTEGER, year_ended INTEGER, publisher_id INTEGER,
        issue_count INTEGER, deleted INTEGER, norm_name TEXT, initials TEXT);
    CREATE TABLE issue (id INTEGER PRIMARY KEY, series_id INTEGER, number TEXT,
        key_date TEXT, sort_code INTEGER, title TEXT, variant_of_id INTEGER, deleted INTEGER);
    CREATE TABLE publisher (id INTEGER PRIMARY KEY, name TEXT, deleted INTEGER);
    CREATE TABLE series_bond (id INTEGER PRIMARY KEY, origin_id INTEGER, target_id INTEGER,
        origin_issue_id INTEGER, target_issue_id INTEGER, bond_type_id INTEGER);
    CREATE TABLE series_bond_type (id INTEGER PRIMARY KEY, name TEXT);
    """

    private func buildGCDFixture(at path: String, seedSQL: String = "", failureContext: String) {
        var fdb: OpaquePointer?
        sqlite3_open(path, &fdb)
        defer { sqlite3_close(fdb) }
        var errmsg: UnsafeMutablePointer<Int8>?
        sqlite3_exec(fdb, Self.gcdSchemaDDL + seedSQL, nil, nil, &errmsg)
        if let errmsg {
            Issue.record("\(failureContext) fixture build failed: \(String(cString: errmsg))")
        }
    }

    private func buildBondFixture(at path: String) {
        buildGCDFixture(at: path, seedSQL: """
            INSERT INTO publisher VALUES (1, 'Marvel', 0);
            INSERT INTO series VALUES (100, 'Tales of Suspense', 'Tales of Suspense', 1959, 1968, 1, 99, 0, 'tales of suspense', 'TOS');
            INSERT INTO series VALUES (101, 'Captain America', 'Captain America', 1968, 1996, 1, 300, 0, 'captain america', 'CA');
            INSERT INTO series_bond_type VALUES (2, 'major_name_numbering_continues');
            INSERT INTO series_bond VALUES (1, 100, 101, NULL, NULL, 2);
            """, failureContext: "bond")
    }

    private func buildASMVolumeFixture(at path: String) {
        buildGCDFixture(at: path, seedSQL: """
            INSERT INTO publisher VALUES (1, 'Marvel', 0);
            -- GCD catalogs both real-world volumes under the identical display name.
            INSERT INTO series VALUES (1570, 'The Amazing Spider-Man', 'Amazing Spider-Man', 1963, 1998, 1, 443, 0, 'amazing spider man', 'ASM');
            INSERT INTO series VALUES (11288, 'The Amazing Spider-Man', 'Amazing Spider-Man', 1999, 2013, 1, 700, 0, 'amazing spider man', 'ASM');
            INSERT INTO issue VALUES (1, 1570, '441', '1998-11-00', 441, '', NULL, 0);
            -- Vol. 2's own issue #1 -- plain "1", no parenthetical legacy annotation, matching the
            -- real GCD data gap for the earliest issues of the restart.
            INSERT INTO issue VALUES (2, 11288, '1', '1999-01-00', 1, '', NULL, 0);
            -- Real GCD data actually catalogs this exact continuation as a bond -- the
            -- legacy-numbering fallback now walks this graph rather than guessing the nearest
            -- same-named series by year, so the fixture needs to reflect that real relationship.
            INSERT INTO series_bond_type VALUES (1, 'major_name_numbering_continues');
            INSERT INTO series_bond VALUES (1, 1570, 11288, NULL, NULL, 1);
            """, failureContext: "ASM volume")
    }

    @Test func recomputeGCDMatchesBackfillsVolumeFromMatchedGCDSeriesYear() throws {
        try insertComic(series: "ASM (1963)", issue: "441", title: "ASM (1963) #441", year: 1998)
        try insertComic(series: "ASM (1963)", issue: "442", title: "ASM (1963) #442", year: 1999)

        let path = NSTemporaryDirectory() + "asm-volume-fixture-\(UUID().uuidString).sqlite"
        buildASMVolumeFixture(at: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = OfflineMetadataStore(path: path)

        db.recomputeGCDMatches(store: store)

        let comics = db.allComics(series: "ASM (1963)", sortOrder: .manual)
        let issue441 = try #require(comics.first { $0.issueNumber == "441" })
        let issue442 = try #require(comics.first { $0.issueNumber == "442" })
        #expect(issue441.volume == "1963", "matched against Vol. 1 (GCD series year_began 1963)")
        #expect(issue442.volume == "1999", "matched via legacy-numbering continuation into Vol. 2 (year_began 1999)")
        #expect(issue441.gcdSeriesName == "The Amazing Spider-Man")
        #expect(issue442.gcdSeriesName == "The Amazing Spider-Man")
        #expect(issue442.gcdIssueNumber == "442", "should store the real legacy number, not Vol. 2's internal '1'")
    }

    @Test("hasComicInfo: true is what actually protects this -- the field, not merely \"already has a value\", is what tells recomputeGCDMatches this Volume came from the file's own ComicInfo.xml rather than an earlier (possibly since-corrected) GCD guess")
    func recomputeGCDMatchesNeverOverwritesAnExistingVolume() throws {
        try insertComic(series: "ASM (1963)", issue: "442", title: "ASM (1963) #442", year: 1999,
                        volume: "custom-volume-tag", hasComicInfo: true)

        let path = NSTemporaryDirectory() + "asm-volume-fixture-\(UUID().uuidString).sqlite"
        buildASMVolumeFixture(at: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = OfflineMetadataStore(path: path)

        db.recomputeGCDMatches(store: store)

        let comic = try #require(db.allComics(series: "ASM (1963)", sortOrder: .manual).first)
        #expect(comic.volume == "custom-volume-tag", "a comic's own Volume (e.g. from ComicInfo.xml) must never be overwritten by a GCD-derived guess")
    }

    @Test func recomputeGCDMatchesClearsStaleMatchWhenNoLongerFound() throws {
        try insertComic(series: "ASM (1963)", issue: "441", title: "ASM (1963) #441", year: 1998)

        let path = NSTemporaryDirectory() + "asm-volume-fixture-\(UUID().uuidString).sqlite"
        buildASMVolumeFixture(at: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        db.recomputeGCDMatches(store: OfflineMetadataStore(path: path))

        var comic = try #require(db.allComics(series: "ASM (1963)", sortOrder: .manual).first)
        #expect(comic.gcdSeriesName == "The Amazing Spider-Man")
        #expect(comic.volume == "1963")

        // Simulate the same comic no longer matching anything on a later pass (e.g. an ambiguity
        // fix retracting a previously-confident guess) via a valid but empty GCD database.
        let emptyPath = NSTemporaryDirectory() + "empty-gcd-fixture-\(UUID().uuidString).sqlite"
        buildGCDFixture(at: emptyPath, failureContext: "empty GCD")
        defer { try? FileManager.default.removeItem(atPath: emptyPath) }

        db.recomputeGCDMatches(store: OfflineMetadataStore(path: emptyPath))
        comic = try #require(db.allComics(series: "ASM (1963)", sortOrder: .manual).first)
        #expect(comic.gcdSeriesName == nil, "a stale match must be cleared, not left in place, once it's no longer found")
        #expect(comic.gcdMatchConfidence == nil)
        #expect(comic.volume == nil, "a GCD-derived volume (hasComicInfo false) must be retracted along with its match -- keeping it around would silently misattribute this comic to the wrong volume forever")
    }

    @Test func setManualGCDMatchSetsAllFieldsAndMarksSourceManual() throws {
        try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        let comic = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)

        db.setManualGCDMatch(comicId: comic.id, gcdIssueId: 555, seriesName: "Batman", issueNumber: "1",
                             coverDate: "2016-06-00", seriesYearBegan: 2016)

        let updated = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)
        #expect(updated.gcdSeriesName == "Batman")
        #expect(updated.gcdIssueNumber == "1")
        #expect(updated.gcdMatchConfidence == 100, "a human pick is certain, not a scored guess")
        #expect(updated.volume == "2016", "backfills volume the same way an automatic match would, since has_comicinfo is false")

        let info = try #require(db.metadataInspectorInfo(comicId: comic.id))
        #expect(info.gcdMatchSource == "manual")
        #expect(info.gcdMatchReason == "Manually matched")
    }

    @Test func setManualGCDMatchNeverOverwritesARealComicInfoVolume() throws {
        try insertComic(series: "Batman", issue: "1", title: "Batman #1", volume: "custom-volume-tag", hasComicInfo: true)
        let comic = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)

        db.setManualGCDMatch(comicId: comic.id, gcdIssueId: 555, seriesName: "Batman", issueNumber: "1",
                             coverDate: nil, seriesYearBegan: 2016)

        let updated = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)
        #expect(updated.volume == "custom-volume-tag")
    }

    @Test func clearManualGCDMatchRevertsToAutoAndClearsFields() throws {
        try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        let comic = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)
        db.setManualGCDMatch(comicId: comic.id, gcdIssueId: 555, seriesName: "Batman", issueNumber: "1",
                             coverDate: "2016-06-00", seriesYearBegan: 2016)

        db.clearManualGCDMatch(comicId: comic.id)

        let updated = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)
        #expect(updated.gcdSeriesName == nil)
        #expect(updated.gcdMatchConfidence == nil)
        let info = try #require(db.metadataInspectorInfo(comicId: comic.id))
        #expect(info.gcdMatchSource == "auto", "must revert to automatic control so the next rescan can re-evaluate it")
    }

    @Test("The core guarantee a manual override exists for: recomputeGCDMatches must never revert a user's deliberate pick, even one that deliberately disagrees with what the automatic matcher would have found")
    func recomputeGCDMatchesNeverOverwritesAManualMatch() throws {
        try insertComic(series: "ASM (1963)", issue: "441", title: "ASM (1963) #441", year: 1998)
        let comic = try #require(db.allComics(series: "ASM (1963)", sortOrder: .manual).first)

        // Deliberately set a manual match that disagrees with what the real ASM fixture would
        // automatically produce, so overwriting it would be obviously detectable.
        db.setManualGCDMatch(comicId: comic.id, gcdIssueId: 999, seriesName: "A Deliberately Wrong Series",
                             issueNumber: "1", coverDate: nil, seriesYearBegan: 1940)

        let path = NSTemporaryDirectory() + "asm-volume-fixture-\(UUID().uuidString).sqlite"
        buildASMVolumeFixture(at: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        db.recomputeGCDMatches(store: OfflineMetadataStore(path: path))

        let stillManual = try #require(db.allComics(series: "ASM (1963)", sortOrder: .manual).first)
        #expect(stillManual.gcdSeriesName == "A Deliberately Wrong Series", "recomputeGCDMatches must skip manually-matched rows entirely")
        #expect(stillManual.volume == "1940")
    }

    @Test func manualGCDMatchDetailsReturnsOnlyManuallyMatchedComicsWithRealIssueIds() throws {
        try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        try insertComic(series: "Batman", issue: "2", title: "Batman #2")
        let comics = db.allComics(series: "Batman", sortOrder: .manual)
        let manual = try #require(comics.first { $0.issueNumber == "1" })

        db.setManualGCDMatch(comicId: manual.id, gcdIssueId: 555, seriesName: "Batman",
                             issueNumber: "1", coverDate: "2016-06-00", seriesYearBegan: 2016)

        let details = db.manualGCDMatchDetails()
        #expect(details.count == 1, "the non-manually-matched comic must not appear")
        let detail = try #require(details.first)
        #expect(detail.comicId == manual.id)
        #expect(detail.gcdIssueId == 555)
        #expect(detail.seriesName == "Batman")
        #expect(detail.coverDate == "2016-06-00")
    }

    @Test("BackupService's restore path deliberately does NOT touch volume -- a backup doesn't carry the matched series' start year, so blindly writing one (or NULL) here could silently clobber a volume value set by an unrelated automatic match since the backup was taken")
    func restoreManualGCDMatchDoesNotTouchVolume() throws {
        try insertComic(series: "Batman", issue: "1", title: "Batman #1", volume: "existing-volume")
        let comic = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)

        db.restoreManualGCDMatch(comicId: comic.id, gcdIssueId: 555, seriesName: "Batman",
                                 issueNumber: "1", coverDate: "2016-06-00")

        let updated = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)
        #expect(updated.gcdSeriesName == "Batman")
        #expect(updated.gcdIssueNumber == "1")
        #expect(updated.volume == "existing-volume", "restore must never touch volume")
        let info = try #require(db.metadataInspectorInfo(comicId: comic.id))
        #expect(info.gcdMatchSource == "manual")
    }

    @Test("Mirrors the same bare-key staleness bug fixed for recomputeReadingOrder: a caller (e.g. LibraryScanner re-deriving series after a folder rename) may only know a comic's publisher:series, not its volume. If that comic was already volume-backfilled by an earlier pass, its real composite groupKey includes a volume suffix the caller's bare key never had -- without expanding it, this row would be silently skipped and its (possibly now-wrong, post-rename) GCD match would never get refreshed")
    func recomputeGCDMatchesBareAffectedGroupKeyStillMatchesAfterVolumeAlreadyBackfilled() throws {
        try insertComic(series: "ASM (1963)", issue: "441", title: "ASM (1963) #441", year: 1998, volume: "1963")

        let path = NSTemporaryDirectory() + "asm-volume-fixture-\(UUID().uuidString).sqlite"
        buildASMVolumeFixture(at: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        db.recomputeGCDMatches(affectedGroupKeys: ["Marvel:ASM (1963)"], store: OfflineMetadataStore(path: path))

        let comic = try #require(db.allComics(series: "ASM (1963)", sortOrder: .manual).first)
        #expect(comic.gcdSeriesName == "The Amazing Spider-Man", "a bare publisher:series key must still resolve to a row whose real groupKey now includes a volume")
    }

    @Test func idForHashFindsExistingComic() throws {
        try insertComic(series: "Hashed", issue: "1", title: "Hashed #1", fileHash: "abc123")
        let comic = try #require(db.allComics(series: "Hashed", sortOrder: .manual).first)
        #expect(db.idForHash("abc123") == comic.id)
    }

    @Test func idForHashReturnsNilForUnknownHash() {
        #expect(db.idForHash("does-not-exist") == nil)
    }

    @Test func autoPopulateSeriesLinksFromGCDResolvesAbbreviatedLocalFolders() throws {
        try insertComic(series: "TOS (Modern)", issue: "99", title: "TOS (Modern) #99")
        try insertComic(series: "Captain America", issue: "100", title: "Captain America #100")

        let bondPath = NSTemporaryDirectory() + "bond-fixture-\(UUID().uuidString).sqlite"
        buildBondFixture(at: bondPath)
        defer { try? FileManager.default.removeItem(atPath: bondPath) }
        let bondStore = OfflineMetadataStore(path: bondPath)

        db.autoPopulateSeriesLinksFromGCD(store: bondStore)

        let links = db.seriesLinks()
        #expect(links.count == 1)
        #expect(links.first?.parentSeries == "TOS (Modern)")
        #expect(links.first?.childSeries == "Captain America")
        #expect(links.first?.source == "gcd")
    }

    @Test func autoPopulateSeriesLinksFromGCDDoesNotOverwriteManualLink() throws {
        try insertComic(series: "TOS (Modern)", issue: "99", title: "TOS (Modern) #99")
        try insertComic(series: "Captain America", issue: "100", title: "Captain America #100")
        try insertComic(series: "SomeOtherParent", issue: "1", title: "SomeOtherParent #1")
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "SomeOtherParent",
                          childPublisher: "Marvel", childSeries: "Captain America", source: "manual")

        let bondPath = NSTemporaryDirectory() + "bond-fixture-\(UUID().uuidString).sqlite"
        buildBondFixture(at: bondPath)
        defer { try? FileManager.default.removeItem(atPath: bondPath) }
        let bondStore = OfflineMetadataStore(path: bondPath)

        db.autoPopulateSeriesLinksFromGCD(store: bondStore)

        let links = db.seriesLinks()
        #expect(links.count == 1)
        #expect(links.first?.parentSeries == "SomeOtherParent")
        #expect(links.first?.source == "manual")
    }

    @Test func legacyNumberAlwaysWinsForMainlineIssues() throws {
        try insertComic(series: "Chrono", issue: "1", title: "Chrono #1", year: 2020, month: 6)
        try insertComic(series: "Chrono", issue: "2", title: "Chrono #2", year: 2020, month: 1)
        db.recomputeReadingOrder(mode: .intelligent)
        let comics = db.allComics(series: "Chrono", sortOrder: .manual)
        let issue1 = try #require(comics.first { $0.title == "Chrono #1" })
        let issue2 = try #require(comics.first { $0.title == "Chrono #2" })
        let issue1Position = try #require(issue1.readingOrderPosition)
        let issue2Position = try #require(issue2.readingOrderPosition)
        #expect(issue1Position < issue2Position)
        #expect(issue1.readingOrderConfidence == 100)
        #expect(issue2.readingOrderConfidence == 100)
    }

    @Test func filenameModeRoundTripsExactlyToOriginalPosition() throws {
        for n in 1...5 { try insertComic(series: "Roundtrip", issue: "\(n)", title: "Roundtrip #\(n)") }
        try insertComic(series: "Roundtrip", issue: "1", title: "Roundtrip Annual #1")
        let original = db.allComics(series: "Roundtrip", sortOrder: .manual).map(\.position)

        db.recomputeReadingOrder(mode: .intelligent)
        db.recomputeReadingOrder(mode: .legacyNumber)
        db.recomputeReadingOrder(mode: .publicationDate)
        db.recomputeReadingOrder(mode: .filename)

        let afterRoundTrip = db.allComics(series: "Roundtrip", sortOrder: .manual).map(\.position)
        #expect(original == afterRoundTrip, "switching modes must never mutate the underlying filename/legacy position")
    }

    @Test func autoPlacedSpecialIssuesExcludesManualAndAlwaysLastBand() throws {
        for n in 1...20 { try insertComic(series: "Cosmic", issue: "\(n)", title: "Cosmic #\(n)", year: 2000, month: (n % 12) + 1) }
        try insertComic(series: "Cosmic", issue: "1", title: "Cosmic Annual #1", year: 2000, month: 6)
        try insertComic(series: "Solo", issue: "1", title: "Solo Special #1")
        db.recomputeReadingOrder(mode: .intelligent)

        let suggestions = db.autoPlacedSpecialIssues()
        #expect(suggestions.contains { $0.title == "Cosmic Annual #1" })
        #expect(suggestions.contains { $0.title == "Solo Special #1" } == false, "confidence-0 always-last placements aren't real suggestions to review")
        #expect(suggestions.allSatisfy { ($0.readingOrderConfidence ?? 0) >= 1 && ($0.readingOrderConfidence ?? 0) <= 99 })
    }

    @Test func autoPlacedSpecialIssuesExcludesManuallyOverriddenIssues() throws {
        for n in 1...20 { try insertComic(series: "Cosmic", issue: "\(n)", title: "Cosmic #\(n)", year: 2000, month: (n % 12) + 1) }
        try insertComic(series: "Cosmic", issue: "1", title: "Cosmic Annual #1", year: 2000, month: 6)
        db.recomputeReadingOrder(mode: .intelligent)
        let annual = try #require(db.allComics(series: "Cosmic", sortOrder: .manual).first { $0.title.contains("Annual") })

        db.setReadingOrderOverride(comicId: annual.id, position: annual.position)
        db.recomputeReadingOrder(mode: .intelligent)

        let suggestions = db.autoPlacedSpecialIssues()
        #expect(suggestions.contains { $0.id == annual.id } == false, "a manually-confirmed placement (confidence 100) shouldn't still show up as a pending suggestion")
    }

    @Test func tier1TwoAnnualsInSameGapGetDistinctPositions() throws {
        for n in 1...5 { try insertComic(series: "Multi", issue: "\(n)", title: "Multi #\(n)", year: 2000, month: n * 2) }
        try insertComic(series: "Multi", issue: "1", title: "Multi Annual #1", year: 2000, month: 5, day: 1)
        try insertComic(series: "Multi", issue: "2", title: "Multi Annual #2", year: 2000, month: 5, day: 15)
        db.recomputeReadingOrder(mode: .intelligent)
        let comics = db.allComics(series: "Multi", sortOrder: .manual)
        let a1 = try #require(comics.first { $0.title == "Multi Annual #1" })
        let a2 = try #require(comics.first { $0.title == "Multi Annual #2" })
        #expect(a1.readingOrderPosition != a2.readingOrderPosition, "two annuals in the same date gap must not collide on the same position")
        let a1Position = try #require(a1.readingOrderPosition)
        let a2Position = try #require(a2.readingOrderPosition)
        #expect(a1Position < a2Position, "earlier-dated annual should sort first")
    }

    @Test func tier5UnrelatedSeriesAlwaysLastSpecialsDontCollide() throws {
        try insertComic(series: "SoloA", issue: "1", title: "SoloA Special #1")
        try insertComic(series: "SoloB", issue: "1", title: "SoloB Special #1")
        db.recomputeReadingOrder(mode: .intelligent)
        let a = try #require(db.allComics(series: "SoloA", sortOrder: .manual).first)
        let b = try #require(db.allComics(series: "SoloB", sortOrder: .manual).first)
        #expect(a.readingOrderPosition != b.readingOrderPosition, "always-last specials from different series must not collide")
    }

    @Test func groupKeySplitsByVolumeForReadingOrder() throws {
        try insertComic(series: "Relaunched", issue: "1", title: "Relaunched #1", year: 1990, month: 1, volume: "1990")
        try insertComic(series: "Relaunched", issue: "2", title: "Relaunched #2", year: 1990, month: 3, volume: "1990")
        try insertComic(series: "Relaunched", issue: "1", title: "Relaunched #1", year: 2020, month: 1, volume: "2020")
        try insertComic(series: "Relaunched", issue: "2", title: "Relaunched #2", year: 2020, month: 3, volume: "2020")
        try insertComic(series: "Relaunched", issue: "1", title: "Relaunched Annual #1", year: 1990, month: 2, volume: "1990")
        db.recomputeReadingOrder(mode: .intelligent)
        let comics = db.allComics(series: "Relaunched", sortOrder: .manual)
        let annual = try #require(comics.first { $0.title.contains("Annual") })
        let run1990Issue1 = try #require(comics.first { $0.title == "Relaunched #1" && $0.volume == "1990" })
        let run1990Issue2 = try #require(comics.first { $0.title == "Relaunched #2" && $0.volume == "1990" })
        let annualPosition = try #require(annual.readingOrderPosition)
        let run1990Issue1Position = try #require(run1990Issue1.readingOrderPosition)
        let run1990Issue2Position = try #require(run1990Issue2.readingOrderPosition)
        #expect(annualPosition > run1990Issue1Position)
        #expect(annualPosition < run1990Issue2Position)
        #expect(annual.readingOrderConfidence == 100, "should be placed via its own run's date interpolation, not left unplaced by cross-run contamination")
    }

    @Test func alternateNumberPreferredForSeriesLinkChild() throws {
        try insertComic(series: "OldRun", issue: "700", title: "OldRun #700")
        try insertComic(series: "NewRun", issue: "1", title: "NewRun #1", alternateNumber: "701")
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "OldRun", childPublisher: "Marvel", childSeries: "NewRun")
        db.recomputeReadingOrder(mode: .intelligent)
        let old = try #require(db.allComics(series: "OldRun", sortOrder: .manual).first)
        let new = try #require(db.allComics(series: "NewRun", sortOrder: .manual).first)
        let oldPosition = try #require(old.readingOrderPosition)
        let newPosition = try #require(new.readingOrderPosition)
        #expect(oldPosition < newPosition, "chained continuation should sort after the parent using its continuity number")
    }

    @Test("recomputeGCDMatches' own verified continuity number (gcd_issue_number) drives cross-volume placement even with no ComicInfo <AlternateNumber> tag -- closes the gap where these two systems didn't talk to each other")
    func gcdIssueNumberDrivesChildPlacementWhenNoAlternateNumber() throws {
        try insertComic(series: "OldRun", issue: "700", title: "OldRun #700")
        try insertComic(series: "NewRun", issue: "1", title: "NewRun #1")
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "OldRun", childPublisher: "Marvel", childSeries: "NewRun")
        let newRunId = try #require(db.allComics(series: "NewRun", sortOrder: .manual).first).id
        // Simulates what recomputeGCDMatches writes on a real legacy-numbering match: the true
        // continuity number lands in gcd_issue_number, with no ComicInfo.xml tag involved at all.
        #expect(db.exec("UPDATE comics SET gcd_issue_number = '701' WHERE id = \(newRunId)"))

        db.recomputeReadingOrder(mode: .intelligent)

        let old = try #require(db.allComics(series: "OldRun", sortOrder: .manual).first)
        let new = try #require(db.allComics(series: "NewRun", sortOrder: .manual).first)
        let oldPosition = try #require(old.readingOrderPosition)
        let newPosition = try #require(new.readingOrderPosition)
        #expect(oldPosition < newPosition,
                "the GCD-verified continuity number should place the child after the parent, not at its own volume-relative #1")
    }

    @Test func addSeriesLinkVolumeAwareSameSeriesNameDifferentVolumesAreDistinctChildren() throws {
        try insertComic(series: "Parent1", issue: "1", title: "Parent1 #1")
        try insertComic(series: "Parent2", issue: "1", title: "Parent2 #1")
        try insertComic(series: "ASM", issue: "1", title: "ASM #1", volume: "1")
        try insertComic(series: "ASM", issue: "1", title: "ASM #1", volume: "1999")

        #expect(db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "Parent1",
                                  childPublisher: "Marvel", childSeries: "ASM", childVolume: "1"))
        #expect(db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "Parent2",
                                  childPublisher: "Marvel", childSeries: "ASM", childVolume: "1999"),
                "a different volume of the same series name must be linkable as its own distinct child")
        #expect(db.seriesLinks().count == 2)

        #expect(db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "Parent2",
                                  childPublisher: "Marvel", childSeries: "ASM", childVolume: "1") == false,
                "the same (publisher, series, volume) can't be linked to two different parents")
    }

    @Test func removeSeriesLinkVolumeAwareOnlyRemovesMatchingVolume() throws {
        try insertComic(series: "Parent1", issue: "1", title: "Parent1 #1")
        try insertComic(series: "Parent2", issue: "1", title: "Parent2 #1")
        try insertComic(series: "ASM", issue: "1", title: "ASM #1", volume: "1")
        try insertComic(series: "ASM", issue: "1", title: "ASM #1", volume: "1999")
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "Parent1", childPublisher: "Marvel", childSeries: "ASM", childVolume: "1")
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "Parent2", childPublisher: "Marvel", childSeries: "ASM", childVolume: "1999")

        db.removeSeriesLink(childPublisher: "Marvel", childSeries: "ASM", childVolume: "1")

        let links = db.seriesLinks()
        #expect(links.count == 1)
        #expect(links.first?.childVolume == "1999")
    }

    @Test func seriesLinkVolumeAwareLegacyRenumberedVolumesInterleaveCorrectly() throws {
        // Volume 1: the original run, including its own Annual #1.
        for n in 1...3 { try insertComic(series: "Amazing Spider-Man", issue: "\(n)", title: "ASM #\(n)", volume: "1") }
        try insertComic(series: "Amazing Spider-Man", issue: "1", title: "ASM Annual #1", volume: "1")

        // Volume 2: Marvel's 1999 renumbering-restart, later reverted to legacy numbering --
        // still tagged with a distinct Volume, and with its own Annual #1.
        for n in 1...3 { try insertComic(series: "Amazing Spider-Man", issue: "\(n)", title: "ASM Vol2 #\(n)", volume: "1999") }
        try insertComic(series: "Amazing Spider-Man", issue: "1", title: "ASM Vol2 Annual #1", volume: "1999")

        db.recomputeReadingOrder(mode: .intelligent)
        #expect(db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "Amazing Spider-Man", parentVolume: "1",
                                  childPublisher: "Marvel", childSeries: "Amazing Spider-Man", childVolume: "1999"))
        db.recomputeReadingOrder(mode: .intelligent)

        let comics = db.allComics(series: "Amazing Spider-Man", sortOrder: .manual)
        let vol1 = comics.filter { $0.volume == "1" }
        let vol2 = comics.filter { $0.volume == "1999" }

        let vol1Max = try #require(vol1.compactMap(\.readingOrderPosition).max())
        let vol2Min = try #require(vol2.compactMap(\.readingOrderPosition).min())
        #expect(vol2Min > vol1Max, "Volume 2 must sort entirely after Volume 1 once linked as its continuation")

        let vol1Annual = try #require(vol1.first { $0.title.contains("Annual") })
        let vol2Annual = try #require(vol2.first { $0.title.contains("Annual") })
        let vol1AnnualPosition = try #require(vol1Annual.readingOrderPosition)
        let vol2AnnualPosition = try #require(vol2Annual.readingOrderPosition)
        #expect(vol1AnnualPosition < vol2AnnualPosition,
                "Annual #1 (Volume 1) must appear before Annual #1 (Volume 2)")
    }

    @Test("Real bug: renaming a series (e.g. via a folder rename, or the \"Manage Series\" rename feature) left any series_links row still pointing at the OLD name -- orphaning it, since it no longer matches anything in `comics`, silently breaking whatever volume-aware reading-order chaining that link was providing")
    func renameSeriesKeepsSeriesLinksInSync() throws {
        try insertComic(series: "Old Parent", issue: "1", title: "Old Parent #1")
        try insertComic(series: "Old Child", issue: "1", title: "Old Child #1")
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "Old Parent", childPublisher: "Marvel", childSeries: "Old Child")

        db.renameSeries(oldName: "Old Child", publisher: "Marvel", newName: "New Child")

        let link = try #require(db.seriesLinks().first)
        #expect(link.childSeries == "New Child")
        #expect(link.parentSeries == "Old Parent", "renaming the child must not affect the parent side")
    }

    @Test func renameSeriesMigratesCustomCoverReaderPrefsAndManualOrder() throws {
        let comicId = try insertComic(series: "Old Name", publisher: "DC", issue: "1", title: "Old Name #1")
        db.setSeriesCover(series: "Old Name", publisher: "DC", comicId: comicId)
        db.setSeriesReaderPrefs(series: "Old Name", publisher: "DC", fitMode: "fitWidth", rtl: true,
                                doubleSpread: true, scrollMode: false)
        db.reorderSeriesGroups(groupName: "Batman", publisher: "DC", orderedSeries: ["Old Name", "Something Else"])

        db.renameSeries(oldName: "Old Name", publisher: "DC", newName: "New Name")

        #expect(db.currentSeriesCover(series: "New Name", publisher: "DC") == comicId)
        #expect(db.currentSeriesCover(series: "Old Name", publisher: "DC") == nil)
        let prefs = db.seriesReaderPrefs(series: "New Name", publisher: "DC")
        #expect(prefs?.fitMode == "fitWidth")
        #expect(prefs?.rtl == true)
        #expect(db.seriesReaderPrefs(series: "Old Name", publisher: "DC") == nil)
    }

    @Test func batchUpdateFolderMetaKeepsSeriesLinksInSyncAfterFolderRename() throws {
        try insertComic(series: "ASM (1963)", issue: "1", title: "ASM (1963) #1", volume: "1963")
        try insertComic(series: "ASM (Modern)", issue: "1", title: "ASM (Modern) #1", volume: "1999")
        db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "ASM (1963)", parentVolume: "1963",
                          childPublisher: "Marvel", childSeries: "ASM (Modern)", childVolume: "1999")

        let renamed = try #require(db.allComics(series: "ASM (1963)", sortOrder: .manual).first)
        db.batchUpdateFolderMeta([(id: renamed.id, pub: nil, char: nil, ser: "ASM (Classic)", title: renamed.title, issueNumber: nil, year: nil, group: nil)])

        let link = try #require(db.seriesLinks().first)
        #expect(link.parentSeries == "ASM (Classic)", "a folder-rename-driven metadata update must keep series_links in sync, not orphan it")
        #expect(link.parentVolume == "1963", "the link's volume must be untouched by a series-name-only rename")
    }

    @Test func batchUpdateFolderMetaFillsEmptyYearFromFilename() throws {
        try insertComic(series: "ASM (Modern)", issue: "1", title: "The_Amazing_Spider-Man_(2014)_Issue_#1")
        let comic = try #require(db.allComics(series: "ASM (Modern)", sortOrder: .manual).first)
        #expect(comic.year == nil)

        db.batchUpdateFolderMeta([(id: comic.id, pub: nil, char: nil, ser: nil, title: comic.title, issueNumber: nil, year: 2014, group: nil)])

        let updated = try #require(db.allComics(series: "ASM (Modern)", sortOrder: .manual).first)
        #expect(updated.year == 2014)
    }

    @Test func batchUpdateFolderMetaNeverOverwritesAnExistingYear() throws {
        try insertComic(series: "ASM (Modern)", issue: "1", title: "ASM (Modern) #1", year: 1998)
        let comic = try #require(db.allComics(series: "ASM (Modern)", sortOrder: .manual).first)

        db.batchUpdateFolderMeta([(id: comic.id, pub: nil, char: nil, ser: nil, title: comic.title, issueNumber: nil, year: 2014, group: nil)])

        let updated = try #require(db.allComics(series: "ASM (Modern)", sortOrder: .manual).first)
        #expect(updated.year == 1998, "a real existing year (e.g. from ComicInfo.xml) must never be overwritten by a filename guess")
    }

    @Test func addSeriesLinkRejectsDirectCycle() {
        #expect(db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "A", childPublisher: "Marvel", childSeries: "B"))
        #expect(db.addSeriesLink(parentPublisher: "Marvel", parentSeries: "B", childPublisher: "Marvel", childSeries: "A") == false,
                "linking B as a continuation of A after A is already a continuation of B would form a cycle")
    }

    @Test func seriesLinkCyclesDetectsExistingCycle() {
        _ = db.exec("INSERT INTO series_links (parent_publisher, parent_series, child_publisher, child_series, sequence_order, source) VALUES ('Marvel','X','Marvel','Y',1,'manual')")
        _ = db.exec("INSERT INTO series_links (parent_publisher, parent_series, child_publisher, child_series, sequence_order, source) VALUES ('Marvel','Y','Marvel','X',2,'manual')")
        let cycles = db.seriesLinkCycles()
        #expect(cycles.isEmpty == false, "an existing X<->Y cycle should be detected")
    }

    @Test("ComicInfo's own Format field should classify even when no keyword appears in the title/series text")
    func classifyPrefersComicInfoFormatOverKeywords() {
        let type = ReadingOrderEngine.classify(issueNumber: "1", title: "Batman", series: "Batman", format: "Annual")
        #expect(type == .annual)
    }

    @Test func duplicateGroupsFlagsByteIdenticalFilesAcrossDifferentVolumes() throws {
        try insertComic(series: "Reprint", issue: "1", title: "Reprint #1", volume: "1990", fileHash: "abc123")
        try insertComic(series: "Reprint", issue: "1", title: "Reprint #1", volume: "2020", fileHash: "abc123")
        let groups = db.duplicateGroups()
        #expect(groups.contains { $0.count == 2 && $0.allSatisfy { $0.fileHash == "abc123" } },
                "byte-identical files must be flagged even when volume metadata would otherwise split them apart")
    }

    @Test func confirmAutoPlacementPersistsAcrossFreshDatabaseInstance() throws {
        for n in 1...20 { try insertComic(series: "Persist", issue: "\(n)", title: "Persist #\(n)", year: 2000, month: (n % 12) + 1) }
        try insertComic(series: "Persist", issue: "1", title: "Persist Annual #1", year: 2000, month: 6)
        db.recomputeReadingOrder(mode: .intelligent)
        let annual = try #require(db.allComics(series: "Persist", sortOrder: .manual).first { $0.title.contains("Annual") })

        db.setReadingOrderOverride(comicId: annual.id, position: try #require(annual.readingOrderPosition), reason: "Confirmed correct")
        db.recomputeReadingOrder(mode: .intelligent)

        let reopened = DatabaseManager(dbPath: tempPath)
        let suggestions = reopened.autoPlacedSpecialIssues()
        #expect(suggestions.contains { $0.id == annual.id } == false, "a confirmed placement must stay confirmed across a fresh app launch, not just within one session")
    }

    @Test func seriesWithNumberingGapsDetectsGap() throws {
        try insertComic(series: "Gappy", issue: "1", title: "Gappy #1")
        try insertComic(series: "Gappy", issue: "2", title: "Gappy #2")
        try insertComic(series: "Gappy", issue: "4", title: "Gappy #4")
        let gaps = db.seriesWithNumberingGaps()
        #expect(gaps.contains { $0.series == "Gappy" })
    }

    @Test func seriesWithNumberingGapsNoFalsePositiveForCompleteRun() throws {
        for n in 1...5 { try insertComic(series: "Complete", issue: "\(n)", title: "Complete #\(n)") }
        let gaps = db.seriesWithNumberingGaps()
        #expect(gaps.contains { $0.series == "Complete" } == false)
    }

    @Test func seriesWithMultipleVolumesDetectsDistinctVolumes() throws {
        try insertComic(series: "MultiVol", issue: "1", title: "MultiVol #1", volume: "1990")
        try insertComic(series: "MultiVol", issue: "1", title: "MultiVol #1", volume: "2020")
        let volumes = db.seriesWithMultipleVolumes()
        #expect(volumes.contains { $0.series == "MultiVol" })
    }

    @Test func seriesWithNumberingMismatchesDetectsZeroPaddingDifference() throws {
        try insertComic(series: "Padded", issue: "1", title: "Padded #1")
        try insertComic(series: "Padded", issue: "01", title: "Padded #01")
        let mismatches = db.seriesWithNumberingMismatches()
        #expect(mismatches.contains { $0.series == "Padded" })
    }

    @Test func missingComicInfoCountExcludesNullRows() throws {
        try insertComic(series: "Untracked", issue: "1", title: "Untracked #1")
        #expect(db.missingComicInfoCount() == 0)
    }

    @Test func corruptArchiveCountCountsZeroPageComics() throws {
        try insertComic(series: "Broken", issue: "1", title: "Broken #1")
        let comic = try #require(db.allComics(series: "Broken", sortOrder: .manual).first)
        _ = db.exec("UPDATE comics SET page_count = 0 WHERE id = \(comic.id)")
        let count = db.corruptArchiveCount()
        #expect(count >= 1)
    }

    @Test func libraryHealthAnalyzerIncludesAllNewChecks() throws {
        try insertComic(series: "Gappy2", issue: "1", title: "Gappy2 #1")
        try insertComic(series: "Gappy2", issue: "3", title: "Gappy2 #3")
        try insertComic(series: "MultiVol2", issue: "1", title: "MultiVol2 #1", volume: "1990")
        try insertComic(series: "MultiVol2", issue: "1", title: "MultiVol2 #1", volume: "2020")
        let report = LibraryHealthAnalyzer.analyze(db: db)
        #expect(report.isEmpty == false)
        #expect(report.numberingGaps.contains { $0.series == "Gappy2" })
        #expect(report.multipleVolumes.contains { $0.series == "MultiVol2" })
    }

    @Test func metadataInspectorInfoReturnsExpectedFields() throws {
        try insertComic(series: "Inspected", issue: "1", title: "Inspected Annual #1",
                        volume: "2020", format: "Annual", alternateNumber: "700")
        let comic = try #require(db.allComics(series: "Inspected", sortOrder: .manual).first)
        let info = db.metadataInspectorInfo(comicId: comic.id)
        #expect(info != nil)
        #expect(info?.comicType == .annual)
        #expect(info?.alternateNumber == "700")
        #expect(info?.comic.volume == "2020")
    }

    @Test func proposedFilenameNilWhenAlreadyCorrectlyNamed() throws {
        try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        let comic = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)
        _ = db.exec("UPDATE comics SET file_path = '/tmp/Batman #001.cbz' WHERE id = \(comic.id)")
        #expect(db.proposedFilename(comicId: comic.id) == nil)
    }

    @Test func proposedFilenameCleansUpUnderscoresInTheActualFilename() throws {
        try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        let comic = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)
        _ = db.exec("UPDATE comics SET file_path = '/tmp/Batman_#001.cbz' WHERE id = \(comic.id)")
        #expect(db.proposedFilename(comicId: comic.id) == "Batman #001.cbz")
    }

    @Test("proposedFilename only cleans up the file's own actual name -- it no longer reconstructs a name from series/GCD metadata, so a 'wrong' name with nothing to clean (no underscores/extra whitespace) proposes no change at all")
    func proposedFilenameNeverReconstructsFromMetadata() throws {
        try insertComic(series: "ASM (1963)", issue: "1", title: "The Amazing Spider-Man #1")
        let comic = try #require(db.allComics(series: "ASM (1963)", sortOrder: .manual).first)
        _ = db.exec("UPDATE comics SET gcd_series_name = 'The Amazing Spider-Man' WHERE id = \(comic.id)")
        _ = db.exec("UPDATE comics SET file_path = '/tmp/completely-different-name.cbz' WHERE id = \(comic.id)")
        #expect(db.proposedFilename(comicId: comic.id) == nil)
    }

    @Test func metadataInspectorInfoDuplicateCountReflectsRealMatches() throws {
        try insertComic(series: "Dup", issue: "1", title: "Dup #1")
        try insertComic(series: "Dup", issue: "1", title: "Dup #1 (2nd Printing)")
        let comics = db.allComics(series: "Dup", sortOrder: .manual)
        let info = db.metadataInspectorInfo(comicId: try #require(comics.first).id)
        #expect(info?.duplicateMatchCount == 1)
    }

    @Test func nextComicReturnsTheFollowingIssueInReadingOrder() throws {
        for n in 1...3 { try insertComic(series: "Batman", issue: "\(n)", title: "Batman #\(n)") }
        let comics = db.allComics(series: "Batman", sortOrder: .manual)
        let issue1 = try #require(comics.first { $0.issueNumber == "1" })
        let issue2 = try #require(comics.first { $0.issueNumber == "2" })
        let next = db.nextComic(after: issue1)
        #expect(next?.id == issue2.id)
    }

    @Test func nextComicIsNilAtTheEndOfTheSeries() throws {
        for n in 1...2 { try insertComic(series: "Robin", issue: "\(n)", title: "Robin #\(n)") }
        let comics = db.allComics(series: "Robin", sortOrder: .manual)
        let lastIssue = try #require(comics.first { $0.issueNumber == "2" })
        #expect(db.nextComic(after: lastIssue) == nil)
    }

    @Test func nextComicDoesNotCrossIntoADifferentSeries() throws {
        try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        try insertComic(series: "Detective Comics", issue: "1", title: "Detective Comics #1")
        let batman1 = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)
        #expect(db.nextComic(after: batman1) == nil)
    }

    @Test func unreadOnlyExcludesComicsWithAnyProgress() throws {
        let unreadId = try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        let startedId = try insertComic(series: "Batman", issue: "2", title: "Batman #2")
        db.updateProgress(comicId: startedId, page: 3)
        let results = db.allComics(series: "Batman", sortOrder: .manual, unreadOnly: true)
        #expect(results.contains { $0.id == unreadId })
        #expect(!results.contains { $0.id == startedId })
    }

    @Test func minRatingFiltersOutAnythingBelowThreshold() throws {
        let highId = try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        let lowId = try insertComic(series: "Batman", issue: "2", title: "Batman #2")
        db.setRating(highId, rating: 5)
        db.setRating(lowId, rating: 2)
        let results = db.allComics(series: "Batman", sortOrder: .manual, minRating: 4)
        #expect(results.contains { $0.id == highId })
        #expect(!results.contains { $0.id == lowId })
    }

    @Test func searchFindsComicsByNotesReviewAndTag() throws {
        let notedId = try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        let reviewedId = try insertComic(series: "Batman", issue: "2", title: "Batman #2")
        let taggedId = try insertComic(series: "Batman", issue: "3", title: "Batman #3")
        db.setComicNotes(notedId, notes: "Lent to Alex")
        db.setComicReview(reviewedId, review: "Best Joker story ever written")
        db.addTag(name: "must-reread", to: taggedId)

        #expect(db.allComics(search: "Alex").contains { $0.id == notedId })
        #expect(db.allComics(search: "Joker story").contains { $0.id == reviewedId })
        #expect(db.allComics(search: "must-reread").contains { $0.id == taggedId })
    }

    @Test func comicIdsUnderFolderFindsOnlyComicsInThatFolder() throws {
        let insideId = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                                            title: "Batman #1", filePath: "/Library/DC/Batman/Batman #1.cbz")
        let outsideId = try insertTestComic(into: db, series: "Superman", publisher: "DC", issue: "1",
                                             title: "Superman #1", filePath: "/Library/DC/Superman/Superman #1.cbz")
        let ids = db.comicIds(underFolder: "/Library/DC/Batman")
        #expect(ids.contains(insideId))
        #expect(!ids.contains(outsideId))
    }

    @Test func comicIdsUnderFolderDoesNotMatchASimilarlyNamedSiblingFolder() throws {
        let comicsId = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                                            title: "Batman #1", filePath: "/Library/Comics/Batman #1.cbz")
        let comics2Id = try insertTestComic(into: db, series: "Superman", publisher: "DC", issue: "1",
                                             title: "Superman #1", filePath: "/Library/Comics2/Superman #1.cbz")
        let ids = db.comicIds(underFolder: "/Library/Comics")
        #expect(ids.contains(comicsId))
        #expect(!ids.contains(comics2Id))
    }

    @Test func softDeleteRecordsWhetherItWasUserOrMissingInitiated() throws {
        let deletedId = try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        let missingId = try insertComic(series: "Batman", issue: "2", title: "Batman #2")
        db.softDelete([deletedId], reason: "user")
        db.softDelete([missingId], reason: "missing")
        let trashed = db.trashedComics()
        #expect(trashed.first { $0.id == deletedId }?.deletedReason == "user")
        #expect(trashed.first { $0.id == missingId }?.deletedReason == "missing")
    }

    @Test func softDeleteDefaultsToUserReason() throws {
        let id = try insertComic(series: "Batman", issue: "1", title: "Batman #1")
        db.softDelete([id])
        #expect(db.trashedComics().first { $0.id == id }?.deletedReason == "user")
    }

    @Test func nextComicRespectsManualReadingOrderOverrides() throws {
        let firstId = try insertComic(series: "Annuals", issue: "1", title: "Annuals #1")
        let annualId = try insertComic(series: "Annuals", issue: nil, title: "Annuals Annual #1")
        let secondId = try insertComic(series: "Annuals", issue: "2", title: "Annuals #2")
        // Force the annual to sit between #1 and #2, same as Series Manager would via a manual
        // reorder -- nextComic should follow this override, not raw filename/issue-number order.
        db.setReadingOrderOverride(comicId: annualId, position: 150, reason: "Manually placed")
        db.setReadingOrderOverride(comicId: firstId, position: 100, reason: "Manually placed")
        db.setReadingOrderOverride(comicId: secondId, position: 200, reason: "Manually placed")
        let first = try #require(db.comic(id: firstId))
        #expect(db.nextComic(after: first)?.id == annualId)
    }
}
