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
            issue_count INTEGER, deleted INTEGER, norm_name TEXT);
        CREATE TABLE issue (id INTEGER PRIMARY KEY, series_id INTEGER, number TEXT,
            key_date TEXT, sort_code INTEGER, title TEXT, variant_of_id INTEGER, deleted INTEGER);
        CREATE TABLE publisher (id INTEGER PRIMARY KEY, name TEXT, deleted INTEGER);
        CREATE TABLE series_bond (id INTEGER PRIMARY KEY, origin_id INTEGER, target_id INTEGER,
            origin_issue_id INTEGER, target_issue_id INTEGER, bond_type_id INTEGER);
        CREATE TABLE series_bond_type (id INTEGER PRIMARY KEY, name TEXT);

        INSERT INTO publisher VALUES (1, 'Marvel', 0);
        INSERT INTO publisher VALUES (2, 'DC Comics', 0);

        -- Two distinct real-world runs sharing a name, disambiguated by year.
        INSERT INTO series VALUES (100, 'The Amazing Spider-Man', 'Amazing Spider-Man', 1963, 1998, 1, 443, 0, 'amazing spider man');
        INSERT INTO series VALUES (101, 'The Amazing Spider-Man', 'Amazing Spider-Man', 1999, 2013, 1, 700, 0, 'amazing spider man');
        INSERT INTO series VALUES (102, 'Superior Spider-Man', 'Superior Spider-Man', 2013, 2014, 1, 34, 0, 'superior spider man');

        INSERT INTO issue VALUES (1000, 100, '12', '1964-05-00', 500, '', NULL, 0);
        INSERT INTO issue VALUES (1001, 100, '13', '1964-06-00', 501, '', NULL, 0);
        INSERT INTO issue VALUES (1002, 101, '12', '2000-01-15', 900, '', NULL, 0);
        INSERT INTO issue VALUES (1003, 100, '12', '1964-05-00', 499, 'variant', 1000, 0);

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
    }

    func test_lookupIssue_wrongYearMatchesOtherRun() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "12", year: 2000)
        XCTAssertEqual(match?.coverDate, "2000-01-15")
    }

    func test_lookupIssue_noPublisherOrYearSignalReturnsNil() {
        // No corroborating signal at all — must not guess.
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: nil, issueNumber: "12", year: nil)
        XCTAssertNil(match)
    }

    func test_lookupIssue_prefersNonVariant() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "12", year: 1964)
        XCTAssertEqual(match?.gcdIssueId, 1000) // not the variant (1003)
    }

    func test_lookupIssue_unknownSeriesReturnsNil() {
        let match = store.lookupIssue(series: "Totally Made Up Comic", publisher: "Marvel", issueNumber: "1", year: 2020)
        XCTAssertNil(match)
    }

    func test_allSeriesBonds_returnsRealContinuation() {
        let bonds = store.allSeriesBonds()
        XCTAssertTrue(bonds.contains { $0.originName == "The Amazing Spider-Man" && $0.targetName == "Superior Spider-Man" })
    }

    func test_isAvailable_falseWhenFileMissing() {
        let missing = OfflineMetadataStore(path: "/nonexistent/path.sqlite")
        XCTAssertFalse(missing.isAvailable)
        XCTAssertNil(missing.lookupIssue(series: "Anything", publisher: "Anyone", issueNumber: "1", year: 2020))
        XCTAssertTrue(missing.allSeriesBonds().isEmpty)
    }
}
