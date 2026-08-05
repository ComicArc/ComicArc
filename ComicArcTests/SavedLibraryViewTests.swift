import Testing
import Foundation
@testable import ComicArc

/// Uses an isolated `UserDefaults` suite (never `.standard`), same pattern as
/// LibraryFoldersTests, so these tests can never read or mutate a real app's saved views.
final class SavedLibraryViewTests {
    private let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        suiteName = "SavedLibraryViewTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func readReturnsEmptyWhenNothingSaved() {
        #expect(SavedLibraryViews.read(defaults: defaults).isEmpty)
    }

    @Test func writeThenReadRoundTripsAllFields() {
        let view = SavedLibraryView(name: "Unread Marvel", publisher: "Marvel", tag: nil,
                                     sortOrder: .dateAdded, unreadOnly: true, minRatingFilter: 3,
                                     searchText: "spider")
        SavedLibraryViews.write([view], defaults: defaults)

        let read = SavedLibraryViews.read(defaults: defaults)
        #expect(read == [view])
    }

    @Test func destinationPrefersTagOverPublisherWhenBothSomehowSet() {
        let view = SavedLibraryView(name: "X", publisher: "DC", tag: "noir",
                                     sortOrder: .manual, unreadOnly: false, minRatingFilter: 0, searchText: "")
        #expect(view.destination == .tag("noir"))
    }

    @Test func destinationFallsBackToPublisherThenLibrary() {
        let withPublisher = SavedLibraryView(name: "X", publisher: "DC", tag: nil,
                                              sortOrder: .manual, unreadOnly: false, minRatingFilter: 0, searchText: "")
        #expect(withPublisher.destination == .publisher("DC"))

        let plain = SavedLibraryView(name: "X", publisher: nil, tag: nil,
                                      sortOrder: .manual, unreadOnly: false, minRatingFilter: 0, searchText: "")
        #expect(plain.destination == .library)
    }

    @Test func readIgnoresGarbageInput() {
        defaults.set("not json", forKey: SavedLibraryViews.key)
        #expect(SavedLibraryViews.read(defaults: defaults).isEmpty)
    }
}
