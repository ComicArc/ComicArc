import XCTest
@testable import ComicArc

final class ComicArcTests: XCTestCase {

    func test_destination_codable_simpleCase() throws {
        for dest: AppDestination in [.library, .continueReading, .favorites, .readingList,
                                      .runs, .stats, .history, .settings] {
            let decoded = try roundTrip(dest)
            XCTAssertEqual(dest, decoded, "Codable round-trip failed for \(dest)")
        }
    }

    func test_destination_codable_publisherCase() throws {
        let dest = AppDestination.publisher("Marvel")
        XCTAssertEqual(try roundTrip(dest), dest)
    }

    func test_destination_codable_tagCase() throws {
        let dest = AppDestination.tag("horror")
        XCTAssertEqual(try roundTrip(dest), dest)
    }

    func test_destination_codable_publisherWithSpecialCharacters() throws {
        let dest = AppDestination.publisher("DC Comics & Vertigo")
        XCTAssertEqual(try roundTrip(dest), dest)
    }

    func test_destination_title_publisher() {
        XCTAssertEqual(AppDestination.publisher("Marvel").title, "Marvel")
    }

    func test_destination_title_tag() {
        XCTAssertEqual(AppDestination.tag("horror").title, "#horror")
    }

    func test_destination_icon_nonEmpty() {
        let all: [AppDestination] = [.library, .continueReading, .favorites, .readingList,
                                      .publisher(""), .tag(""), .runs, .stats, .history,
                                      .settings]
        for dest in all {
            XCTAssertFalse(dest.icon.isEmpty, "icon empty for \(dest)")
        }
    }

    @MainActor
    func test_select_updatesDestination() {
        let vm = LibraryViewModel.shared
        let original = vm.destination
        vm.select(.stats)
        XCTAssertEqual(vm.destination, .stats)
        vm.select(original)
    }

    @MainActor
    func test_select_clearsDrillDown() {
        let vm = LibraryViewModel.shared
        vm.selectedSeries = "Amazing Spider-Man"
        vm.selectedGroup  = nil
        vm.select(.continueReading)
        XCTAssertNil(vm.selectedSeries)
        vm.select(.library)
    }

    @MainActor
    func test_select_resetsTagToGroupedView() {
        let vm = LibraryViewModel.shared
        vm.select(.tag("horror"))
        vm.select(.library)

        XCTAssertTrue(vm.useGroupedView)
    }

    @MainActor
    func test_selectedSection_matchesDestination() {
        let vm = LibraryViewModel.shared
        let mapping: [(AppDestination, LibraryViewModel.SidebarSection)] = [
            (.library,         .library),
            (.continueReading, .continueReading),
            (.favorites,       .favorites),
            (.readingList,     .readingList),
            (.runs,            .runs),
            (.stats,           .stats),
            (.history,         .history),
        ]
        for (dest, expected) in mapping {
            vm.select(dest)
            XCTAssertEqual(vm.selectedSection, expected, "selectedSection wrong for \(dest)")
        }
        vm.select(.library)
    }

    @MainActor
    func test_activePublisher_setAndCleared() {
        let vm = LibraryViewModel.shared
        vm.select(.publisher("DC"))
        XCTAssertEqual(vm.activePublisher, "DC")
        vm.select(.library)
        XCTAssertNil(vm.activePublisher)
    }

    @MainActor
    func test_activeTag_setAndCleared() {
        let vm = LibraryViewModel.shared
        vm.select(.tag("sci-fi"))
        XCTAssertEqual(vm.activeTag, "sci-fi")
        vm.select(.library)
        XCTAssertNil(vm.activeTag)
    }

    @MainActor
    func test_select_tag_setsUseGroupedViewFalse() {
        let vm = LibraryViewModel.shared
        vm.select(.library)
        XCTAssertTrue(vm.useGroupedView)
        vm.select(.tag("action"))
        XCTAssertFalse(vm.useGroupedView)
        vm.select(.library)
    }

    @MainActor
    func test_select_nonTag_setsUseGroupedViewTrue() {
        let vm = LibraryViewModel.shared
        vm.select(.tag("horror"))
        XCTAssertFalse(vm.useGroupedView)
        for dest: AppDestination in [.library, .continueReading, .favorites, .readingList, .runs, .stats, .history, .settings] {
            vm.select(dest)
            XCTAssertTrue(vm.useGroupedView, "useGroupedView should be true after selecting \(dest)")
        }
        vm.select(.library)
    }

    @MainActor
    func test_select_settings_doesNotCrash() {
        let vm = LibraryViewModel.shared
        vm.select(.settings)
        XCTAssertEqual(vm.destination, .settings)
        vm.select(.library)
    }

    func test_destination_settings_hasTitle() {
        XCTAssertFalse(AppDestination.settings.title.isEmpty)
    }

    func test_destination_settings_hasIcon() {
        XCTAssertFalse(AppDestination.settings.icon.isEmpty)
    }

    func test_destination_publisher_emptyString_hasTitle() {
        let dest = AppDestination.publisher("")
        XCTAssertNotNil(dest.title)
    }

    func test_destination_codable_publisherEmptyString() throws {
        let dest = AppDestination.publisher("")
        XCTAssertEqual(try roundTrip(dest), dest)
    }

    @MainActor
    func test_destination_persistsToUserDefaults() throws {
        let dest = AppDestination.stats
        let data = try JSONEncoder().encode(dest)
        UserDefaults.standard.set(data, forKey: "test.destination")
        let loaded = try JSONDecoder().decode(
            AppDestination.self,
            from: UserDefaults.standard.data(forKey: "test.destination")!
        )
        XCTAssertEqual(dest, loaded)
        UserDefaults.standard.removeObject(forKey: "test.destination")
    }

    func test_sortClassifier_regularNumberedIssue_isNotSpecial() {
        XCTAssertFalse(ComicSortClassifier.isSpecialIssue(
            issueNumber: "1", title: "Amazing Spider-Man (1963-2012) #001", series: "Amazing Spider-Man"))
        XCTAssertFalse(ComicSortClassifier.isSpecialIssue(
            issueNumber: "442", title: "Amazing Spider-Man (1963-2012) #442", series: "Amazing Spider-Man"))
    }

    func test_sortClassifier_annualInTitle_isSpecial() {
        XCTAssertTrue(ComicSortClassifier.isSpecialIssue(
            issueNumber: "1", title: "Amazing Spider-Man (1963-2012) Annual #001", series: "Amazing Spider-Man"))
    }

    func test_sortClassifier_annualInSeriesName_isSpecial() {
        XCTAssertTrue(ComicSortClassifier.isSpecialIssue(
            issueNumber: "1", title: "The_Amazing_Spider-Man_(1999)_Annual_1",
            series: "The Amazing Spider-Man (1999) Annual"))
    }

    func test_sortClassifier_otherKeywords_areSpecial() {
        for keyword in ["Special", "Holiday", "One-Shot", "Preview", "Giant-Size", "King-Size"] {
            XCTAssertTrue(ComicSortClassifier.isSpecialIssue(
                issueNumber: nil, title: "Some Series \(keyword) #1", series: "Some Series"),
                "Expected '\(keyword)' to be classified as a special issue")
        }
    }

    func test_sortClassifier_caseInsensitive() {
        XCTAssertTrue(ComicSortClassifier.isSpecialIssue(issueNumber: nil, title: "annual edition", series: ""))
        XCTAssertTrue(ComicSortClassifier.isSpecialIssue(issueNumber: nil, title: "ANNUAL EDITION", series: ""))
    }

    func test_sortClassifier_missingIssueNumber_fallsBackToTitleSeries() {
        XCTAssertFalse(ComicSortClassifier.isSpecialIssue(issueNumber: nil, title: "Batman #1", series: "Batman"))
        XCTAssertTrue(ComicSortClassifier.isSpecialIssue(issueNumber: nil, title: "Batman Annual", series: "Batman"))
    }

    func test_sortClassifier_allFieldsEmpty_isNotSpecial() {
        XCTAssertFalse(ComicSortClassifier.isSpecialIssue(issueNumber: nil, title: "", series: ""))
    }

    func test_sortClassifier_ordinaryStoryArcTitles_areNotSpecial() {
        XCTAssertFalse(ComicSortClassifier.isSpecialIssue(
            issueNumber: "3", title: "The Sinister Six", series: "Amazing Spider-Man"))
        XCTAssertFalse(ComicSortClassifier.isSpecialIssue(
            issueNumber: "12", title: "Batman: Legend Reborn", series: "Detective Comics"))
    }

    func test_sortClassifier_seededPosition_specialAlwaysAfterMainline() {
        let mainlinePos = ComicSortClassifier.seededPosition(
            issueNumber: "999", title: "Amazing Spider-Man #999", series: "Amazing Spider-Man", numericIssueOrId: 999)
        let specialPos = ComicSortClassifier.seededPosition(
            issueNumber: "1", title: "Amazing Spider-Man Annual #001", series: "Amazing Spider-Man", numericIssueOrId: 1)
        XCTAssertLessThan(mainlinePos, specialPos,
            "A high-numbered mainline issue must still sort before a low-numbered annual")
    }

    func test_sortClassifier_seededPosition_specialsOrderedAmongThemselves() {
        let annual1 = ComicSortClassifier.seededPosition(
            issueNumber: "1", title: "Annual", series: "X", numericIssueOrId: 1)
        let annual2 = ComicSortClassifier.seededPosition(
            issueNumber: "2", title: "Annual", series: "X", numericIssueOrId: 2)
        XCTAssertLessThan(annual1, annual2)
    }

    func test_sortClassifier_seededPosition_adjacentMainlineIssuesLeaveInterpolationRoom() {
        let issue12 = ComicSortClassifier.seededPosition(
            issueNumber: "12", title: "Batman #12", series: "Batman", numericIssueOrId: 12)
        let issue13 = ComicSortClassifier.seededPosition(
            issueNumber: "13", title: "Batman #13", series: "Batman", numericIssueOrId: 13)
        XCTAssertGreaterThan(issue13 - issue12, 1,
            "Adjacent mainline positions must be spaced more than 1 apart so a chronologically-placed annual has room to sit between them")
        let midpoint = issue12 + (issue13 - issue12) / 2
        XCTAssertGreaterThan(midpoint, issue12)
        XCTAssertLessThan(midpoint, issue13)
    }

    func test_fileNaming_regularIssue() {
        let name = ComicFileNaming.idealFilename(
            series: "Batman", issueNumber: "427", title: "Batman #427", fileExtension: "cbz")
        XCTAssertEqual(name, "Batman #427.cbz")
    }

    func test_fileNaming_preservesSpecialKeyword() {
        let name = ComicFileNaming.idealFilename(
            series: "Amazing Spider-Man", issueNumber: "1",
            title: "Amazing Spider-Man Annual #001", fileExtension: "cbz")
        XCTAssertEqual(name, "Amazing Spider-Man Annual #1.cbz")
    }

    func test_fileNaming_doesNotDuplicateKeywordAlreadyInSeriesName() {

        let name = ComicFileNaming.idealFilename(
            series: "Amazing Spider-Man Annual", issueNumber: "1",
            title: "Amazing Spider-Man Annual #1", fileExtension: "cbz")
        XCTAssertEqual(name, "Amazing Spider-Man Annual #1.cbz")
    }

    func test_fileNaming_sanitizesIllegalPathCharacters() {
        let name = ComicFileNaming.idealFilename(
            series: "Batman: Legend Reborn", issueNumber: "1/2",
            title: "Batman: Legend Reborn #1/2", fileExtension: "cbz")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func test_fileNaming_missingIssueNumberFallsBackToSeriesOnly() {
        let name = ComicFileNaming.idealFilename(
            series: "Watchmen", issueNumber: nil, title: "Watchmen", fileExtension: "cbz")
        XCTAssertEqual(name, "Watchmen.cbz")
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}
