import Testing
import Foundation
@testable import ComicArc

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

struct AppDestinationTests {

    @Test func destinationCodableSimpleCase() throws {
        for dest: AppDestination in [.library, .continueReading, .favorites, .readingList,
                                      .runs, .stats, .history, .settings] {
            let decoded = try roundTrip(dest)
            #expect(dest == decoded, "Codable round-trip failed for \(dest)")
        }
    }

    @Test func destinationCodablePublisherCase() throws {
        let dest = AppDestination.publisher("Marvel")
        #expect(try roundTrip(dest) == dest)
    }

    @Test func destinationCodableTagCase() throws {
        let dest = AppDestination.tag("horror")
        #expect(try roundTrip(dest) == dest)
    }

    @Test func destinationCodablePublisherWithSpecialCharacters() throws {
        let dest = AppDestination.publisher("DC Comics & Vertigo")
        #expect(try roundTrip(dest) == dest)
    }

    @Test func destinationTitlePublisher() {
        #expect(AppDestination.publisher("Marvel").title == "Marvel")
    }

    @Test func destinationTitleTag() {
        #expect(AppDestination.tag("horror").title == "#horror")
    }

    @Test func destinationIconNonEmpty() {
        let all: [AppDestination] = [.library, .continueReading, .favorites, .readingList,
                                      .publisher(""), .tag(""), .runs, .stats, .history,
                                      .settings]
        for dest in all {
            #expect(dest.icon.isEmpty == false, "icon empty for \(dest)")
        }
    }

    @Test func destinationSettingsHasTitle() {
        #expect(AppDestination.settings.title.isEmpty == false)
    }

    @Test func destinationSettingsHasIcon() {
        #expect(AppDestination.settings.icon.isEmpty == false)
    }

    @Test("An empty-string publisher name degrades to an empty title rather than crashing or substituting a placeholder")
    func destinationPublisherEmptyStringHasTitle() {
        let dest = AppDestination.publisher("")
        #expect(dest.title == "")
    }

    @Test func destinationCodablePublisherEmptyString() throws {
        let dest = AppDestination.publisher("")
        #expect(try roundTrip(dest) == dest)
    }
}

/// Exercises `LibraryViewModel.shared`, a process-wide singleton -- serialized so tests that
/// mutate and reset its state can never interleave with one another.
@Suite(.serialized)
@MainActor
struct LibraryViewModelTests {

    @Test func selectUpdatesDestination() {
        let vm = LibraryViewModel.shared
        let original = vm.destination
        vm.select(.stats)
        #expect(vm.destination == .stats)
        vm.select(original)
    }

    @Test func selectClearsDrillDown() {
        let vm = LibraryViewModel.shared
        vm.selectedSeries = "Amazing Spider-Man"
        vm.selectedGroup  = nil
        vm.select(.continueReading)
        #expect(vm.selectedSeries == nil)
        vm.select(.library)
    }

    @Test func selectResetsTagToGroupedView() {
        let vm = LibraryViewModel.shared
        vm.select(.tag("horror"))
        vm.select(.library)

        #expect(vm.useGroupedView)
    }

    @Test func selectedSectionMatchesDestination() {
        let vm = LibraryViewModel.shared
        let mapping: [(AppDestination, LibraryViewModel.SidebarSection)] = [
            (.library,         .library),
            (.continueReading, .continueReading),
            (.favorites,       .favorites),
            (.readingList,     .readingList),
            (.runs,            .runs),
            (.stats,           .stats),
            (.history,         .history),
            (.readingOrderManager, .readingOrderManager),
        ]
        for (dest, expected) in mapping {
            vm.select(dest)
            #expect(vm.selectedSection == expected, "selectedSection wrong for \(dest)")
        }
        vm.select(.library)
    }

    @Test func activePublisherSetAndCleared() {
        let vm = LibraryViewModel.shared
        vm.select(.publisher("DC"))
        #expect(vm.activePublisher == "DC")
        vm.select(.library)
        #expect(vm.activePublisher == nil)
    }

    @Test func activeTagSetAndCleared() {
        let vm = LibraryViewModel.shared
        vm.select(.tag("sci-fi"))
        #expect(vm.activeTag == "sci-fi")
        vm.select(.library)
        #expect(vm.activeTag == nil)
    }

    @Test func selectTagSetsUseGroupedViewFalse() {
        let vm = LibraryViewModel.shared
        vm.select(.library)
        #expect(vm.useGroupedView)
        vm.select(.tag("action"))
        #expect(vm.useGroupedView == false)
        vm.select(.library)
    }

    @Test func selectNonTagSetsUseGroupedViewTrue() {
        let vm = LibraryViewModel.shared
        vm.select(.tag("horror"))
        #expect(vm.useGroupedView == false)
        for dest: AppDestination in [.library, .continueReading, .favorites, .readingList, .runs, .stats, .history, .settings] {
            vm.select(dest)
            #expect(vm.useGroupedView, "useGroupedView should be true after selecting \(dest)")
        }
        vm.select(.library)
    }

    @Test func selectSettingsDoesNotCrash() {
        let vm = LibraryViewModel.shared
        vm.select(.settings)
        #expect(vm.destination == .settings)
        vm.select(.library)
    }

    @Test func destinationPersistsToUserDefaults() throws {
        let suiteName = "AppDestinationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dest = AppDestination.stats
        let data = try JSONEncoder().encode(dest)
        defaults.set(data, forKey: "test.destination")
        let loaded = try JSONDecoder().decode(
            AppDestination.self,
            from: #require(defaults.data(forKey: "test.destination"))
        )
        #expect(dest == loaded)
    }
}

struct ComicSortClassifierTests {

    @Test func regularNumberedIssueIsNotSpecial() {
        #expect(ComicSortClassifier.isSpecialIssue(
            issueNumber: "1", title: "Amazing Spider-Man (1963-2012) #001", series: "Amazing Spider-Man") == false)
        #expect(ComicSortClassifier.isSpecialIssue(
            issueNumber: "442", title: "Amazing Spider-Man (1963-2012) #442", series: "Amazing Spider-Man") == false)
    }

    @Test func annualInTitleIsSpecial() {
        #expect(ComicSortClassifier.isSpecialIssue(
            issueNumber: "1", title: "Amazing Spider-Man (1963-2012) Annual #001", series: "Amazing Spider-Man"))
    }

    @Test func annualInSeriesNameIsSpecial() {
        #expect(ComicSortClassifier.isSpecialIssue(
            issueNumber: "1", title: "The_Amazing_Spider-Man_(1999)_Annual_1",
            series: "The Amazing Spider-Man (1999) Annual"))
    }

    @Test("Various special-issue keywords are classified as special", arguments: [
        "Special", "Holiday", "One-Shot", "Preview", "Giant-Size", "King-Size",
    ])
    func otherKeywordsAreSpecial(keyword: String) {
        #expect(ComicSortClassifier.isSpecialIssue(
            issueNumber: nil, title: "Some Series \(keyword) #1", series: "Some Series"),
            "Expected '\(keyword)' to be classified as a special issue")
    }

    @Test func caseInsensitive() {
        #expect(ComicSortClassifier.isSpecialIssue(issueNumber: nil, title: "annual edition", series: ""))
        #expect(ComicSortClassifier.isSpecialIssue(issueNumber: nil, title: "ANNUAL EDITION", series: ""))
    }

    @Test func missingIssueNumberFallsBackToTitleSeries() {
        #expect(ComicSortClassifier.isSpecialIssue(issueNumber: nil, title: "Batman #1", series: "Batman") == false)
        #expect(ComicSortClassifier.isSpecialIssue(issueNumber: nil, title: "Batman Annual", series: "Batman"))
    }

    @Test func allFieldsEmptyIsNotSpecial() {
        #expect(ComicSortClassifier.isSpecialIssue(issueNumber: nil, title: "", series: "") == false)
    }

    @Test func ordinaryStoryArcTitlesAreNotSpecial() {
        #expect(ComicSortClassifier.isSpecialIssue(
            issueNumber: "3", title: "The Sinister Six", series: "Amazing Spider-Man") == false)
        #expect(ComicSortClassifier.isSpecialIssue(
            issueNumber: "12", title: "Batman: Legend Reborn", series: "Detective Comics") == false)
    }

}


struct ComicFileNamingTests {

    @Test func replacesUnderscoresWithSpaces() {
        let name = ComicFileNaming.cleanedFilename(
            currentName: "The_Amazing_Spider-Man_(1999) #002", fileExtension: "cbz")
        #expect(name == "The Amazing Spider-Man (1999) #002.cbz")
    }

    @Test func collapsesRepeatedWhitespace() {
        let name = ComicFileNaming.cleanedFilename(
            currentName: "Batman   (2016)  #001", fileExtension: "cbz")
        #expect(name == "Batman (2016) #001.cbz")
    }

    @Test func trimsLeadingAndTrailingWhitespace() {
        let name = ComicFileNaming.cleanedFilename(
            currentName: "_Batman #001_", fileExtension: "cbz")
        #expect(name == "Batman #001.cbz")
    }

    @Test func leavesAnAlreadyCleanNameUnchanged() {
        let name = ComicFileNaming.cleanedFilename(
            currentName: "Batman #001", fileExtension: "cbz")
        #expect(name == "Batman #001.cbz")
    }

    @Test func preservesFileExtension() {
        let name = ComicFileNaming.cleanedFilename(
            currentName: "Some_File", fileExtension: "pdf")
        #expect(name == "Some File.pdf")
    }

    @Test func idealFilenamesDerivesFromExistingFilenameNotMetadata() {
        let comic = Comic(
            id: 1, title: "x", filePath: "/lib/Marvel/Spider-Man/The_Amazing_Spider-Man_(1999)_#002.cbz",
            publisher: "Marvel", character: nil, series: "Wrong Series Name", issueNumber: nil,
            pageCount: 1, writer: nil, penciller: nil, year: nil, volume: nil, format: nil,
            storyArc: nil, languageIso: nil, notes: nil, addedAt: "", deletedAt: nil,
            position: 0, fileHash: nil
        )
        let names = ComicFileNaming.idealFilenames(for: [comic])
        #expect(names[1] == "The Amazing Spider-Man (1999) #002.cbz")
    }
}
