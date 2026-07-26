import Testing
import Foundation
import SQLite3
@testable import ComicArc

final class OfflineMetadataStoreTests {
    private let store: OfflineMetadataStore
    private let tempPath: String

    init() {
        tempPath = NSTemporaryDirectory() + "gcd-fixture-\(UUID().uuidString).sqlite"
        Self.buildFixture(at: tempPath)
        store = OfflineMetadataStore(path: tempPath)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    private static func buildFixture(at path: String) {
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
        INSERT INTO publisher VALUES (3, 'Panini France', 0);

        -- Real bug found against the actual production library: a foreign-market reprint house
        -- with no `year_ended` recorded in GCD (read as "still being published" by the year-range
        -- check) shares a name and issue number with a real, differently-published modern comic.
        -- With no publisher-mismatch penalty, this out-scored nothing on year signal alone and
        -- absorbed a same-named/same-numbered issue from a completely different publisher.
        INSERT INTO series VALUES (104, 'Ultimate Spider-Man', 'Ultimate Spider-Man', 2007, NULL, 3, 7, 0, 'ultimate spider man', 'USM');
        INSERT INTO issue VALUES (1009, 104, '1', '2007-03-00', 1, '', NULL, 0);

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
        -- Vol. 1's real last issue, and Vol. 2's real first issue -- GCD stores Vol. 2's own
        -- issue #1 as plain "1" here, with no parenthetical legacy annotation at all (matching
        -- a real GCD data gap for the earliest issues of a legacy-numbered restart).
        INSERT INTO issue VALUES (1005, 100, '441', '1998-11-00', 502, '', NULL, 0);
        INSERT INTO issue VALUES (1006, 101, '1', '1999-01-00', 800, '', NULL, 0);
        -- Real bug: both volumes independently contain an issue "21" (Vol. 1's own 1965 issue,
        -- and Vol. 2's own pre-parenthetical restart issue) -- with no local `year` to
        -- disambiguate them, and issue-count ties (both cap the same tiebreak), a naive
        -- best-scored-candidate-wins approach would silently attach whichever sorts first.
        INSERT INTO issue VALUES (1007, 100, '21', '1965-02-00', 20, '', NULL, 0);
        INSERT INTO issue VALUES (1008, 101, '21', '2000-11-00', 20, '', NULL, 0);

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
        -- Real GCD data catalogs the Vol. 1 -> Vol. 2 legacy-numbering continuation as its own
        -- bond too -- the fallback now walks this graph rather than guessing the nearest
        -- same-named series by year, so the fixture needs the actual relationship present.
        INSERT INTO series_bond VALUES (2, 100, 101, NULL, NULL, 1);
        """
        var errmsg: UnsafeMutablePointer<Int8>?
        sqlite3_exec(db, sql, nil, nil, &errmsg)
        if let errmsg {
            Issue.record("fixture build failed: \(String(cString: errmsg))")
        }
    }

    @Test func normalizeSeriesNameStripsYearAndThe() {
        #expect(OfflineMetadataStore.normalizeSeriesName("The Amazing Spider-Man") == "amazing spider man")
        #expect(OfflineMetadataStore.normalizeSeriesName("Amazing Spider-Man (2016)") == "amazing spider man")
        #expect(OfflineMetadataStore.normalizeSeriesName("Batman Vol. 3") == "batman")
    }

    @Test func lookupIssueDisambiguatesByYear() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "12", year: 1964)
        #expect(match?.coverDate == "1964-05-00")
        #expect(match?.confidence == 100)
        #expect(match?.canonicalSeriesName == "The Amazing Spider-Man")
        #expect(match?.canonicalIssueNumber == "12")
    }

    @Test func lookupIssueCanonicalNumberUnwrapsParens() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "35", year: 2008, comicType: .annual)
        #expect(match?.canonicalSeriesName == "Amazing Spider-Man Annual")
        #expect(match?.canonicalIssueNumber == "35")
    }

    @Test func lookupIssueWrongYearMatchesOtherRun() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "12", year: 2000)
        #expect(match?.coverDate == "2000-01-15")
    }

    @Test func lookupIssueNoPublisherOrYearSignalReturnsNil() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: nil, issueNumber: "12", year: nil)
        #expect(match == nil)
    }

    @Test("Real bug found by running against the actual production library: a 2022 Marvel comic (\"Ultimate Spider-Man\" #1) matched a 2007 Panini France reprint series of the same name, purely because GCD has no year_ended recorded for the reprint (read as \"still being published\") and a known, disagreeing publisher was never treated as a negative signal -- only as a missing bonus")
    func lookupIssueKnownPublisherMismatchDoesNotWinOnYearAlone() {
        let match = store.lookupIssue(series: "Ultimate Spider-Man", publisher: "Marvel", issueNumber: "1", year: 2022)
        #expect(match == nil)
    }

    @Test func lookupIssueKnownPublisherMismatchStillRefusesEvenWithGoodIssueCount() {
        // Sanity check the other direction: the *correctly*-published candidate must still win
        // outright when both exist and years agree with it, not just "mismatch returns nil".
        let match = store.lookupIssue(series: "Ultimate Spider-Man", publisher: "Marvel", issueNumber: "1", year: 2000)
        #expect(match?.gcdIssueId == 1004)
    }

    @Test func lookupIssuePrefersNonVariant() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "12", year: 1964)
        #expect(match?.gcdIssueId == 1000)
    }

    @Test func lookupIssueUnknownSeriesReturnsNil() {
        let match = store.lookupIssue(series: "Totally Made Up Comic", publisher: "Marvel", issueNumber: "1", year: 2020)
        #expect(match == nil)
    }

    @Test func allSeriesBondsReturnsRealContinuation() {
        let bonds = store.allSeriesBonds()
        #expect(bonds.contains { $0.originName == "The Amazing Spider-Man" && $0.targetName == "Superior Spider-Man" })
    }

    @Test func computeInitialsMatchesCommonFanAbbreviations() {
        #expect(OfflineMetadataStore.computeInitials("The Amazing Spider-Man") == "ASM")
        #expect(OfflineMetadataStore.computeInitials("Ultimate Spider-Man") == "USM")
        #expect(OfflineMetadataStore.computeInitials("Amazing Spider-Man (2016)") == "ASM")
        #expect(OfflineMetadataStore.computeInitials("Teenage Mutant Ninja Turtles") == "TMNT")
    }

    @Test func lookupIssueMatchesAbbreviatedSeriesFolderName() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "12", year: 1964)
        #expect(match?.coverDate == "1964-05-00")
    }

    @Test func lookupIssueAbbreviationStillRequiresRealSignal() {
        let match = store.lookupIssue(series: "ASM", publisher: nil, issueNumber: "12", year: nil)
        #expect(match == nil)
    }

    @Test func lookupIssueAbbreviationDoesNotMatchWrongSeries() {
        let match = store.lookupIssue(series: "USM (2000)", publisher: "Marvel", issueNumber: "1", year: 2000)
        #expect(match?.gcdIssueId == 1004)
    }

    @Test func lookupIssueOrdinarySpacedNameIsNotTreatedAsAbbreviation() {
        let match = store.lookupIssue(series: "Superior Spider-Man", publisher: "Marvel", issueNumber: "999", year: 2013)
        #expect(match == nil)
    }

    @Test func lookupIssueAnnualResolvesToCompanionSeries() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "001", year: 1964, comicType: .annual)
        #expect(match?.gcdIssueId == 2000)
        #expect(match?.coverDate == "1964-09-00")
    }

    @Test func lookupIssueZeroPaddedNumberMatchesUnpadded() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "012", year: 1964)
        #expect(match?.gcdIssueId == 1000)
    }

    @Test func lookupIssueRegularIssueDoesNotSearchAnnualCompanion() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "12", year: 1964, comicType: .regular)
        #expect(match?.gcdIssueId == 1000)
    }

    @Test func lookupIssueRetriesLowerScoredCandidateWhenTopChoiceLacksIssue() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "29", year: nil, comicType: .annual)
        #expect(match?.gcdIssueId == 2003)
    }

    @Test func lookupIssueMatchesRestartNumberingWithTrueNumberInParens() {
        let match = store.lookupIssue(series: "ASM (1963)", publisher: "Marvel", issueNumber: "35", year: 2008, comicType: .annual)
        #expect(match?.gcdIssueId == 2002)
    }

    @Test("Real bug: Marvel continued ASM's original numbering into Vol. 2 for a stretch before GCD's own data starts annotating the parenthetical legacy number -- Vol. 2's own issue #1 (GCD's plain \"1\", no \"(442)\" annotation) is legacy issue #442 (Vol. 1's last was 441)")
    func lookupIssueLegacyNumberContinuesAcrossVolumeRestart() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "442", year: 2001)
        #expect(match?.gcdIssueId == 1006)
        #expect(match?.canonicalSeriesName == "The Amazing Spider-Man")
        #expect(match?.canonicalIssueNumber == "442", "should keep the real legacy number, not the volume-relative '1'")
        #expect(match?.confidence == 75)
    }

    @Test("#12 exists directly in both volumes -- the fallback must never override a real hit")
    func lookupIssueLegacyNumberFallbackDoesNotFireWhenDirectMatchExists() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "12", year: 1964)
        #expect(match?.gcdIssueId == 1000)
        #expect(match?.confidence == 100)
    }

    @Test func lookupIssueLegacyNumberFallbackNoMatchAnywhereStillReturnsNil() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "99999", year: 2001)
        #expect(match == nil)
    }

    @Test("Real bug found against a live library: modern (2018+) \"Amazing Spider-Man\" issues with no embedded year got silently matched to 1960s Silver Age issues sharing the same number, because both GCD series entries (Vol. 1 and Vol. 2) tie for the same score with no year signal to break the tie -- and both actually contain issue \"21\". A confidently wrong match (attaching a 1965 cover date to a 2019 comic) is worse than no match")
    func lookupIssueAmbiguousTiedCandidatesRefusesToGuess() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "21", year: nil)
        #expect(match == nil)
    }

    @Test("Same shared issue number as the ambiguity test above, but now WITH a year -- that's a real disambiguating signal, so this must still resolve normally, not bail out")
    func lookupIssueYearBreaksWhatWouldOtherwiseBeAnAmbiguousTie() {
        let match = store.lookupIssue(series: "Amazing Spider-Man", publisher: "Marvel", issueNumber: "21", year: 1965)
        #expect(match?.gcdIssueId == 1007)
        #expect(match?.coverDate == "1965-02-00")
    }

    @Test func isAvailableFalseWhenFileMissing() {
        let missing = OfflineMetadataStore(path: "/nonexistent/path.sqlite")
        #expect(missing.isAvailable == false)
        #expect(missing.lookupIssue(series: "Anything", publisher: "Anyone", issueNumber: "1", year: 2020) == nil)
        #expect(missing.allSeriesBonds().isEmpty)
    }

    private func buildThreeHopChainFixture(at path: String) {
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
        -- Three chained relaunches of the same display name, mirroring Marvel's real Legacy
        -- Numbering scheme (which sums across *multiple* prior volumes, not just the nearest one).
        INSERT INTO series VALUES (300, 'Legacy Chain', 'Legacy Chain', 1960, 1969, 1, 50, 0, 'legacy chain', 'LC');
        INSERT INTO series VALUES (301, 'Legacy Chain', 'Legacy Chain', 1970, 1979, 1, 20, 0, 'legacy chain', 'LC');
        INSERT INTO series VALUES (302, 'Legacy Chain', 'Legacy Chain', 1980, 1989, 1, 15, 0, 'legacy chain', 'LC');
        INSERT INTO issue VALUES (3000, 300, '50', '1969-12-00', 50, '', NULL, 0);
        INSERT INTO issue VALUES (3001, 301, '20', '1979-12-00', 20, '', NULL, 0);
        -- The real issue being matched: its own local number is "5", but its true legacy number
        -- (what's actually printed on a 1985 comic using this scheme) is 50 + 20 + 5 = 75.
        INSERT INTO issue VALUES (3002, 302, '5', '1985-06-00', 5, '', NULL, 0);

        INSERT INTO series_bond_type VALUES (1, 'major_name_numbering_continues');
        INSERT INTO series_bond VALUES (1, 300, 301, NULL, NULL, 1);
        INSERT INTO series_bond VALUES (2, 301, 302, NULL, NULL, 1);
        """
        var errmsg: UnsafeMutablePointer<Int8>?
        sqlite3_exec(db, sql, nil, nil, &errmsg)
        if let errmsg { Issue.record("three-hop chain fixture build failed: \(String(cString: errmsg))") }
    }

    @Test("Marvel's real Legacy Numbering scheme sums across multiple prior relaunches, not just the nearest one -- the fallback must walk the full bond chain, not stop after one hop")
    func lookupIssueMultiHopLegacyChainSumsAcrossAllPredecessors() {
        let path = NSTemporaryDirectory() + "three-hop-fixture-\(UUID().uuidString).sqlite"
        buildThreeHopChainFixture(at: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let chainStore = OfflineMetadataStore(path: path)

        let match = chainStore.lookupIssue(series: "Legacy Chain", publisher: "Marvel", issueNumber: "75", year: 1985)
        #expect(match?.gcdIssueId == 3002)
        #expect(match?.coverDate == "1985-06-00")
        #expect(match?.reason.contains("2 earlier volumes") == true)
    }

    @Test("If the bond graph doesn't connect far enough back to explain the printed number, the fallback must still refuse to guess, not mismatch")
    func lookupIssueMultiHopChainRefusesWhenGraphDoesNotReachFarEnough() {
        let path = NSTemporaryDirectory() + "three-hop-fixture-\(UUID().uuidString).sqlite"
        buildThreeHopChainFixture(at: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let chainStore = OfflineMetadataStore(path: path)

        // 50 (series 300) + 20 (series 301) + 5 (series 302's own "5") = 75 is the only number the
        // chain actually explains. A number requiring a fourth, nonexistent predecessor must fail.
        let match = chainStore.lookupIssue(series: "Legacy Chain", publisher: "Marvel", issueNumber: "999", year: 1985)
        #expect(match == nil)
    }

    // MARK: - searchSeries / issuesForSeries (manual "Fix Match" picker)

    @Test func searchSeriesFindsAllSubstringMatchesRegardlessOfVolume() {
        let results = store.searchSeries(query: "Spider-Man")
        // Both Amazing Spider-Man runs (100, 101), Superior Spider-Man (102), both Ultimate
        // Spider-Man entries (103, 104), and both Annual fragments (200, 201) all contain the
        // substring -- a human browsing should see every real candidate, not just the one the
        // automatic scorer would have picked.
        #expect(Set(results.map(\.id)) == [100, 101, 102, 103, 104, 200, 201])
    }

    @Test func searchSeriesIsCaseInsensitive() {
        let results = store.searchSeries(query: "spider-man")
        #expect(results.isEmpty == false)
    }

    @Test func searchSeriesReturnsEmptyForBlankQuery() {
        #expect(store.searchSeries(query: "   ").isEmpty)
    }

    @Test func searchSeriesReturnsEmptyWhenStoreUnavailable() {
        let missing = OfflineMetadataStore(path: "/nonexistent/path.sqlite")
        #expect(missing.searchSeries(query: "Spider-Man").isEmpty)
    }

    @Test("Excludes variant covers (variant_of_id set) and orders by GCD's own sort_code, unwrapping a legacy parenthetical number the same way the automatic matcher does")
    func issuesForSeriesExcludesVariantsAndOrdersBySortCode() {
        // Series 100's real (non-variant) issues: 1007 (sort_code 20), 1000 (500), 1001 (501),
        // 1005 (502) -- 1003 (sort_code 499, a variant of 1000) must be excluded despite sorting
        // earliest by sort_code.
        let issues = store.issuesForSeries(seriesId: 100)
        #expect(issues.map(\.id) == [1007, 1000, 1001, 1005])
        #expect(issues.map(\.number) == ["21", "12", "13", "441"])
    }

    @Test("Restart-numbered issue with the true continuing number in parens unwraps to its plain number, same as lookupIssue's own canonicalIssueNumber")
    func issuesForSeriesUnwrapsLegacyParentheticalNumber() {
        let issues = store.issuesForSeries(seriesId: 201)
        #expect(issues.map(\.number).contains("35"), "issue 2002's raw number '1 (35)' should unwrap to '35'")
    }

    @Test func issuesForSeriesReturnsEmptyForUnknownSeries() {
        #expect(store.issuesForSeries(seriesId: 999999).isEmpty)
    }
}
