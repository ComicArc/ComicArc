import XCTest
import SQLite3
@testable import ComicArc

final class OfflineMetadataStoreTests: XCTestCase {
    private var store: OfflineMetadataStore!
    private var tempPath: String!

    override func setUp() {
        super.setUp()
        tempPath = NSTemporaryDirectory() + "gcd-fixture-\(UUID().uuidString).sqlite"
        buildFixture(at: tempPath)
        store = OfflineMetadataStore(path: tempPath)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(atPath: tempPath)
        super.tearDown()
    }

    private func buildFixture(at path: String) {
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        defer { sqlite3_close(db) }
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
        INSERT INTO publisher VALUES (2, 'DC Comics', 0);

        -- Two distinct real-world runs sharing a name, disambiguated by year.
        INSERT INTO series VALUES (100, 'The Amazing Spider-Man', 'Amazing Spider-Man', 1963, 1998, 1, 443, 0, 'amazing spider man', 'ASM');
        INSERT INTO series VALUES (101, 'The Amazing Spider-Man', 'Amazing Spider-Man', 1999, 2013, 1, 700, 0, 'amazing spider man', 'ASM');
        INSERT INTO series VALUES (102, 'Superior Spider-Man', 'Superior Spider-Man', 2013, 2014, 1, 34, 0, 'superior spider man', 'SSM');
        INSERT INTO series VALUES (103, 'Ultimate Spider-Man', 'Ultimate Spider-Man', 2000, 2009, 1, 133, 0, 'ultimate spider man', 'USM');

        INSERT INTO issue VALUES (1000, 100, '12', '1964-05-00', 500, '', NULL, 0);
        INSERT INTO issue VALUES (1001, 100, '13', '1964-06-00', 501, '', NULL, 0);
        INSERT INTO issue VALUES (1002, 101, '12', '2000-01-15', 900, '', NULL, 0);
        INSERT INTO issue VALUES (1003, 100, '12', '1964-05-00', 499, 'variant', 1000, 0);
        INSERT INTO issue VALUES (1004, 103, '1', '2000-10-00', 1, '', NULL, 0);

        -- GCD catalogs annuals as their own series, separate from the ongoing title.
        INSERT INTO series VALUES (200, 'The Amazing Spider-Man Annual', 'Amazing Spider-Man Annual', 1964, 1994, 1, 28, 0, 'amazing spider man annual', 'ASMA');
        INSERT INTO issue VALUES (2000, 200, '1', '1964-09-00', 1, '', NULL, 0);
        -- A second, later fragment of the SAME annual line under a distinct GCD series id —
        -- real-world relaunches split cataloging like this. Higher issue_count so it would
        -- normally win the score, but it doesn't contain #29 — the matcher must retry the
        -- lower-scored fragment (200) rather than give up.
        INSERT INTO series VALUES (201, 'Amazing Spider-Man Annual', 'Amazing Spider-Man Annual', 2008, 2012, 1, 39, 0, 'amazing spider man annual', 'ASMA');
        INSERT INTO issue VALUES (2001, 201, '36', '2009-08-00', 100, '', NULL, 0);
        -- Restart-numbered with the true continuing number in parens, as GCD does for some
        -- relaunched annual lines.
        INSERT INTO issue VALUES (2002, 201, '1 (35)', '2008-12-00', 99, '', NULL, 0);
        INSERT INTO issue VALUES (2003, 200, '29', '1995-09-00', 2, '', NULL, 0);

        INSERT INTO series_bond_type VALUES (1, 'major_name_numbering_continues');
        INSERT INTO series_bond VALUES (1, 100, 102, NULL, NULL, 1);
        """
        var errmsg: UnsafeMutablePointer<Int8>?
        sqlite3_exec(db, sql, nil, nil, &errmsg)
        if let errmsg { XCTFail("fixture build failed: \(String(cString: errmsg))") }
    }

    func test_normalizeSeriesName_stripsYearAndThe() {
        XCTAssertEqual(OfflineMetadataStore.normalizeSeriesName("The Amazing Spider-Man"), "amazing spider man")
        XCTAssertEqual(OfflineMetadataStore.normalizeSeriesName("Amazing Spider-Man (2016)"), "amazing spider man")
        XCTAssertEqual(OfflineMetadataStore.normalizeSeriesName("Batman Vol. 3"), "batman")
    }

    func test_lookupIssue_disambiguatesByYear() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "12", year: 1964)
        XCTAssertEqual(match?.coverDate, "1964-05-00")
        XCTAssertEqual(match?.confidence, 100)
        XCTAssertEqual(match?.canonicalSeriesName, "The Amazing Spider-Man")
        XCTAssertEqual(match?.canonicalIssueNumber, "12")
    }

    func test_lookupIssue_canonicalNumberUnwrapsParens() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "35", year: 2008, comicType: .annual)
        XCTAssertEqual(match?.canonicalSeriesName, "Amazing Spider-Man Annual")
        XCTAssertEqual(match?.canonicalIssueNumber, "35")
    }

    func test_lookupIssue_wrongYearMatchesOtherRun() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "12", year: 2000)
        XCTAssertEqual(match?.coverDate, "2000-01-15")
    }

    func test_lookupIssue_noPublisherOrYearSignalReturnsNil() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: nil, issueNumber: "12", year: nil)
        XCTAssertNil(match)
    }

    func test_lookupIssue_prefersNonVariant() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "12", year: 1964)
        XCTAssertEqual(match?.gcdIssueId, 1000)
    }

    func test_lookupIssue_unknownSeriesReturnsNil() {
        let match = store.lookupIssue(series: "Totally Made Up Comic", publisher: "Marvel", issueNumber: "1", year: 2020)
        XCTAssertNil(match)
    }

    func test_allSeriesBonds_returnsRealContinuation() {
        let bonds = store.allSeriesBonds()
        XCTAssertTrue(bonds.contains { $0.originName == "The Amazing Spider-Man" && $0.targetName == "Superior Spider-Man" })
    }

    func test_computeInitials_matchesCommonFanAbbreviations() {
        XCTAssertEqual(OfflineMetadataStore.computeInitials("The Amazing Spider-Man"), "ASM")
        XCTAssertEqual(OfflineMetadataStore.computeInitials("Ultimate Spider-Man"), "USM")
        XCTAssertEqual(OfflineMetadataStore.computeInitials("Amazing Spider-Man (2016)"), "ASM")
        XCTAssertEqual(OfflineMetadataStore.computeInitials("Teenage Mutant Ninja Turtles"), "TMNT")
    }

    func test_lookupIssue_matchesAbbreviatedSeriesFolderName() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "12", year: 1964)
        XCTAssertEqual(match?.coverDate, "1964-05-00")
    }

    func test_lookupIssue_abbreviationStillRequiresRealSignal() {
        let match = store.lookupIssue(series: "ASM", publisher: nil, issueNumber: "12", year: nil)
        XCTAssertNil(match)
    }

    func test_lookupIssue_abbreviationDoesNotMatchWrongSeries() {
        let match = store.lookupIssue(series: "USM (2000)", publisher: "Marvel", issueNumber: "1", year: 2000)
        XCTAssertEqual(match?.gcdIssueId, 1004)
    }

    func test_lookupIssue_ordinarySpacedNameIsNotTreatedAsAbbreviation() {
        let match = store.lookupIssue(series: "Superior Spider-Man", publisher: "Marvel", issueNumber: "999", year: 2013)
        XCTAssertNil(match)
    }

    func test_lookupIssue_annualResolvesToCompanionSeries() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "001", year: 1964, comicType: .annual)
        XCTAssertEqual(match?.gcdIssueId, 2000)
        XCTAssertEqual(match?.coverDate, "1964-09-00")
    }

    func test_lookupIssue_zeroPaddedNumberMatchesUnpadded() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "012", year: 1964)
        XCTAssertEqual(match?.gcdIssueId, 1000)
    }

    func test_lookupIssue_regularIssueDoesNotSearchAnnualCompanion() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "12", year: 1964, comicType: .regular)
        XCTAssertEqual(match?.gcdIssueId, 1000)
    }

    func test_lookupIssue_retriesLowerScoredCandidateWhenTopChoiceLacksIssue() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "29", year: nil, comicType: .annual)
        XCTAssertEqual(match?.gcdIssueId, 2003)
    }

    func test_lookupIssue_matchesRestartNumberingWithTrueNumberInParens() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "35", year: 2008, comicType: .annual)
        XCTAssertEqual(match?.gcdIssueId, 2002)
    }

    func test_isAvailable_falseWhenFileMissing() {
        let missing = OfflineMetadataStore(path: "/nonexistent/path.sqlite")
        XCTAssertFalse(missing.isAvailable)
        XCTAssertNil(missing.lookupIssue(series: "Anything", publisher: "Anyone", issueNumber: "1", year: 2020))
        XCTAssertTrue(missing.allSeriesBonds().isEmpty)
    }
}
