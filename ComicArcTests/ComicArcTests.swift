import XCTest
@testable import ComicArc

final class ComicArcTests: XCTestCase {

    // MARK: - AppDestination: Codable round-trips

    func test_destination_codable_simpleCase() throws {
        for dest: AppDestination in [.library, .continueReading, .favorites, .readingList,
                                      .runs, .stats, .history, .creators, .settings] {
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

    // MARK: - AppDestination: properties

    func test_destination_title_publisher() {
        XCTAssertEqual(AppDestination.publisher("Marvel").title, "Marvel")
    }

    func test_destination_title_tag() {
        XCTAssertEqual(AppDestination.tag("horror").title, "#horror")
    }

    func test_destination_icon_nonEmpty() {
        let all: [AppDestination] = [.library, .continueReading, .favorites, .readingList,
                                      .publisher(""), .tag(""), .runs, .stats, .history,
                                      .creators, .settings]
        for dest in all {
            XCTAssertFalse(dest.icon.isEmpty, "icon empty for \(dest)")
        }
    }

    // MARK: - LibraryViewModel: navigation transitions

    @MainActor
    func test_select_updatesDestination() {
        let vm = LibraryViewModel.shared
        let original = vm.destination
        vm.select(.stats)
        XCTAssertEqual(vm.destination, .stats)
        vm.select(original) // restore
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
        // After returning to library, grouped view should be re-enabled
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
            (.creators,        .creators),
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
        vm.select(.library) // restore
    }

    @MainActor
    func test_select_nonTag_setsUseGroupedViewTrue() {
        let vm = LibraryViewModel.shared
        vm.select(.tag("horror"))
        XCTAssertFalse(vm.useGroupedView)
        for dest: AppDestination in [.library, .continueReading, .favorites, .readingList, .runs, .stats, .history, .creators, .settings] {
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

    // MARK: - AppDestination: UserDefaults persistence

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

    // MARK: - Helpers

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}
