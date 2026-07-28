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

    @Test func regularIssue() {
        let name = ComicFileNaming.idealFilename(
            series: "Batman", issueNumber: "427", title: "Batman #427", fileExtension: "cbz")
        #expect(name == "Batman #427.cbz")
    }

    @Test func preservesSpecialKeyword() {
        let name = ComicFileNaming.idealFilename(
            series: "Amazing Spider-Man", issueNumber: "1",
            title: "Amazing Spider-Man Annual #001", fileExtension: "cbz")
        #expect(name == "Amazing Spider-Man Annual #001.cbz")
    }

    @Test func doesNotDuplicateKeywordAlreadyInSeriesName() {
        let name = ComicFileNaming.idealFilename(
            series: "Amazing Spider-Man Annual", issueNumber: "1",
            title: "Amazing Spider-Man Annual #1", fileExtension: "cbz")
        #expect(name == "Amazing Spider-Man Annual #001.cbz")
    }

    @Test func sanitizesIllegalPathCharacters() {
        let name = ComicFileNaming.idealFilename(
            series: "Batman: Legend Reborn", issueNumber: "1/2",
            title: "Batman: Legend Reborn #1/2", fileExtension: "cbz")
        #expect(name.contains("/") == false)
        #expect(name.contains(":") == false)
    }

    @Test func missingIssueNumberFallsBackToSeriesOnly() {
        let name = ComicFileNaming.idealFilename(
            series: "Watchmen", issueNumber: nil, title: "Watchmen", fileExtension: "cbz")
        #expect(name == "Watchmen.cbz")
    }

    @Test("The canonical format's core semantic: the edition marker (Volume tag, or year as a fallback) is always included, even for a comic with zero collisions to disambiguate -- not just added reactively when another comic in the library happens to share the same name")
    func idealFilenameIncludesEditionWhenProvided() {
        let name = ComicFileNaming.idealFilename(
            series: "Batman", issueNumber: "427", title: "Batman #427", fileExtension: "cbz", edition: "2016")
        #expect(name == "Batman (2016) #427.cbz")
    }

    @Test func idealFilenamePadsIssueNumberToThreeDigits() {
        let name = ComicFileNaming.idealFilename(
            series: "Batman", issueNumber: "7", title: "Batman #7", fileExtension: "cbz")
        #expect(name == "Batman #007.cbz")
    }

    @Test func idealFilenamePadsDecimalIssueNumbers() {
        let name = ComicFileNaming.idealFilename(
            series: "Amazing Spider-Man", issueNumber: "1.1", title: "Amazing Spider-Man #1.1", fileExtension: "cbz")
        #expect(name == "Amazing Spider-Man #001.1.cbz")
    }

    @Test("A non-numeric issue number (alternate-numbering schemes, ashcans, etc.) can't be zero-padded meaningfully, so it's left exactly as-is rather than risking a misleading transformation")
    func idealFilenameLeavesNonNumericIssueNumbersUnpadded() {
        let name = ComicFileNaming.idealFilename(
            series: "Deadpool", issueNumber: "1A", title: "Deadpool #1A", fileExtension: "cbz")
        #expect(name == "Deadpool #1A.cbz")
    }

    @Test("Core semantic change from the old collision-driven format: even a single comic with no other library members to collide with still gets its edition marker (here, falling back to year since there's no Volume tag) -- the format is deterministic per-comic, not contingent on what else is in the library")
    func singleComicStillGetsEditionMarker() {
        let input = ComicFileNaming.NamingInput(
            id: 1, series: "Batman", issueNumber: "427", title: "Batman #427",
            fileExtension: "cbz", year: 1988, volume: nil, filePath: "/tmp/a.cbz")
        let names = ComicFileNaming.disambiguatedFilenames(for: [input])
        #expect(names[1] == "Batman (1988) #427.cbz")
    }

    @Test("A comic with neither a Volume tag nor a known year gracefully degrades to the plain series+issue shape -- there's no signal to build an edition marker from, so none is shown rather than a blank/placeholder parenthetical")
    func noEditionSignalFallsBackToPlainName() {
        let input = ComicFileNaming.NamingInput(
            id: 1, series: "Watchmen", issueNumber: nil, title: "Watchmen",
            fileExtension: "cbz", year: nil, volume: nil, filePath: "/tmp/a.cbz")
        let names = ComicFileNaming.disambiguatedFilenames(for: [input])
        #expect(names[1] == "Watchmen.cbz")
    }

    @Test("Three annuals with distinct years now naturally get distinct names via their own edition marker alone -- they never even reach the collision-fallback code path, unlike the old collision-driven scheme")
    func multipleAnnualsWithDifferentYearsAllGetUniqueNames() {
        let inputs = [
            ComicFileNaming.NamingInput(id: 1, series: "Batman", issueNumber: nil, title: "Batman Annual",
                                         fileExtension: "cbz", year: 1988, volume: nil, filePath: "/tmp/a.cbz"),
            ComicFileNaming.NamingInput(id: 2, series: "Batman", issueNumber: nil, title: "Batman Annual",
                                         fileExtension: "cbz", year: 1989, volume: nil, filePath: "/tmp/b.cbz"),
            ComicFileNaming.NamingInput(id: 3, series: "Batman", issueNumber: nil, title: "Batman Annual",
                                         fileExtension: "cbz", year: 1990, volume: nil, filePath: "/tmp/c.cbz"),
        ]
        let names = ComicFileNaming.disambiguatedFilenames(for: inputs)
        #expect(Set(names.values).count == 3, "all three must end up with distinct names")
        #expect(names.values.allSatisfy { $0.contains("Annual") })
        #expect(names[1] == "Batman Annual (1988).cbz")
        #expect(names[2] == "Batman Annual (1989).cbz")
        #expect(names[3] == "Batman Annual (1990).cbz")
    }

    @Test("Two annuals sharing the exact same year -- and no other distinguishing title text -- still collide even with the edition marker included, so the last-resort running-index tier still exists for this genuinely ambiguous case")
    func sameYearCollisionFallsBackToRunningIndex() {
        let inputs = [
            ComicFileNaming.NamingInput(id: 1, series: "Batman", issueNumber: nil, title: "Batman Annual",
                                         fileExtension: "cbz", year: 1988, volume: nil, filePath: "/tmp/a.cbz"),
            ComicFileNaming.NamingInput(id: 2, series: "Batman", issueNumber: nil, title: "Batman Annual",
                                         fileExtension: "cbz", year: 1988, volume: nil, filePath: "/tmp/b.cbz"),
        ]
        let names = ComicFileNaming.disambiguatedFilenames(for: inputs)
        #expect(Set(names.values).count == 2, "same-year collisions must still resolve to distinct names")
        #expect(names[1] == "Batman Annual (1988).cbz")
        #expect(names[2] == "Batman Annual (1988) (2).cbz")
    }

    @Test func noYearAtAllFallsBackToRunningIndex() {
        let inputs = [
            ComicFileNaming.NamingInput(id: 1, series: "Watchmen", issueNumber: nil, title: "Watchmen",
                                         fileExtension: "cbz", year: nil, volume: nil, filePath: "/tmp/b.cbz"),
            ComicFileNaming.NamingInput(id: 2, series: "Watchmen", issueNumber: nil, title: "Watchmen",
                                         fileExtension: "cbz", year: nil, volume: nil, filePath: "/tmp/a.cbz"),
        ]
        let names = ComicFileNaming.disambiguatedFilenames(for: inputs)
        #expect(Set(names.values).count == 2)
        // Deterministic tiebreak by filePath when year is absent for both.
        #expect(names[2] == "Watchmen.cbz", "the entry that sorts first (by path) keeps the plain name")
        #expect(names[1] == "Watchmen (2).cbz")
    }

    @Test func distinctIssueNumbersNeverCollideInTheFirstPlace() {
        let inputs = [
            ComicFileNaming.NamingInput(id: 1, series: "Batman", issueNumber: "1", title: "Batman #1",
                                         fileExtension: "cbz", year: 2016, volume: nil, filePath: "/tmp/a.cbz"),
            ComicFileNaming.NamingInput(id: 2, series: "Batman", issueNumber: "2", title: "Batman #2",
                                         fileExtension: "cbz", year: 2016, volume: nil, filePath: "/tmp/b.cbz"),
        ]
        let names = ComicFileNaming.disambiguatedFilenames(for: inputs)
        #expect(names[1] == "Batman (2016) #001.cbz")
        #expect(names[2] == "Batman (2016) #002.cbz")
    }

    @Test("Real-world case found in an actual library: TPB collections share a series name and have no issue number or year/volume signal, but each one's title already names which collection it is -- that's a far more useful disambiguator than an opaque \"(2)\", \"(3)\"...")
    func tpbCollectionsWithNoIssueNumberUseTitleNotRunningIndex() {
        let inputs = [
            ComicFileNaming.NamingInput(id: 1, series: "Robin (TPB)", issueNumber: nil, title: "Robin v01 - Reborn",
                                         fileExtension: "cbr", year: nil, volume: nil, filePath: "/tmp/a.cbr"),
            ComicFileNaming.NamingInput(id: 2, series: "Robin (TPB)", issueNumber: nil, title: "Robin v02 - Triumphant",
                                         fileExtension: "cbr", year: nil, volume: nil, filePath: "/tmp/b.cbr"),
        ]
        let names = ComicFileNaming.disambiguatedFilenames(for: inputs)
        #expect(names[1] == "Robin (TPB) (Robin v01 - Reborn).cbr")
        #expect(names[2] == "Robin (TPB) (Robin v02 - Triumphant).cbr")
    }

    @Test("The Amazing Spider-Man legacy-numbering scenario: Vol. 1 and Vol. 2 share both the series name and an issue number (both have a #1) -- the comic's own ComicInfo.xml Volume tag becomes each one's edition marker, which is enough to keep their canonical filenames distinct without ever reaching the last-resort tie-break")
    func sameNumberDifferentVolumeUsesVolumeAsEditionMarker() {
        let inputs = [
            ComicFileNaming.NamingInput(id: 1, series: "Amazing Spider-Man", issueNumber: "1", title: "Amazing Spider-Man #1",
                                         fileExtension: "cbz", year: 1963, volume: "1", filePath: "/tmp/a.cbz"),
            ComicFileNaming.NamingInput(id: 2, series: "Amazing Spider-Man", issueNumber: "1", title: "Amazing Spider-Man #1",
                                         fileExtension: "cbz", year: 1999, volume: "1999", filePath: "/tmp/b.cbz"),
        ]
        let names = ComicFileNaming.disambiguatedFilenames(for: inputs)
        #expect(names[1] == "Amazing Spider-Man (1) #001.cbz")
        #expect(names[2] == "Amazing Spider-Man (1999) #001.cbz")
    }

    @Test("Real bug found by running the new canonical format against the actual production library: two numbered issues sharing the same series+edition+issue (a genuine reprint/duplicate) still collide even with the edition marker included. One of them had no ComicInfo.xml, so its `title` was re-derived from its OWN previous, differently-formatted rename output (unpadded issue number, an old-style disambiguator suffix already baked in) -- title-hint's anchored-prefix match against the freshly zero-padded base failed to recognize that stale text as redundant, and returned the whole thing as a bogus \"new\" disambiguator, re-wrapping an old name inside a new one instead of falling through to a clean numeric index. Title-based disambiguation is only trustworthy for no-issue-number entries (TPBs) now -- for a genuine numbered-issue collision, a running index is used unconditionally")
    func numberedIssueCollisionUsesRunningIndexNotStaleTitleText() {
        let inputs = [
            ComicFileNaming.NamingInput(id: 1, series: "Ultimate Spider-Man", issueNumber: "1",
                                         title: "Ultimate Spider-Man #1", fileExtension: "cbz",
                                         year: 2000, volume: "2000", filePath: "/tmp/a.cbz"),
            // Simulates a comic with no ComicInfo.xml whose title was re-derived from an old,
            // already-disambiguated filename under the PREVIOUS naming scheme.
            ComicFileNaming.NamingInput(id: 2, series: "Ultimate Spider-Man", issueNumber: "1",
                                         title: "Ultimate Spider-Man #1 (Vol. 2000, 2)", fileExtension: "cbz",
                                         year: 2000, volume: "2000", filePath: "/tmp/b.cbz"),
        ]
        let names = ComicFileNaming.disambiguatedFilenames(for: inputs)
        #expect(Set(names.values).count == 2, "both must still resolve to distinct names")
        #expect(names[1] == "Ultimate Spider-Man (2000) #001.cbz")
        #expect(names[2] == "Ultimate Spider-Man (2000) #001 (2).cbz",
                "must NOT be '...#001 (Ultimate Spider-Man #1 (Vol. 2000, 2)).cbz' -- that would be re-wrapping stale text")
    }

    @Test("When both a Volume tag and a year are present, Volume wins as the edition marker -- it's the more authoritative signal for \"this is a different run of the same-named series\"")
    func volumeIsPreferredEditionMarkerOverYear() {
        let inputs = [
            ComicFileNaming.NamingInput(id: 1, series: "Batman", issueNumber: nil, title: "Batman Annual Extra Text",
                                         fileExtension: "cbz", year: 1988, volume: "1940", filePath: "/tmp/a.cbz"),
            ComicFileNaming.NamingInput(id: 2, series: "Batman", issueNumber: nil, title: "Batman Annual Extra Text",
                                         fileExtension: "cbz", year: 1989, volume: "2016", filePath: "/tmp/b.cbz"),
        ]
        let names = ComicFileNaming.disambiguatedFilenames(for: inputs)
        #expect(names[1] == "Batman Annual (1940).cbz")
        #expect(names[2] == "Batman Annual (2016).cbz")
    }

    @Test func titleWithSeriesPrefixStripsRedundantPrefix() {
        let inputs = [
            ComicFileNaming.NamingInput(id: 1, series: "Robin (TPB)", issueNumber: nil, title: "Robin (TPB) - Reborn",
                                         fileExtension: "cbr", year: nil, volume: nil, filePath: "/tmp/a.cbr"),
            ComicFileNaming.NamingInput(id: 2, series: "Robin (TPB)", issueNumber: nil, title: "Robin (TPB) - Triumphant",
                                         fileExtension: "cbr", year: nil, volume: nil, filePath: "/tmp/b.cbr"),
        ]
        let names = ComicFileNaming.disambiguatedFilenames(for: inputs)
        #expect(names[1] == "Robin (TPB) (Reborn).cbr")
        #expect(names[2] == "Robin (TPB) (Triumphant).cbr")
    }

    @Test("Real bug found by running the rewritten pipeline against the actual production library: a comic with no ComicInfo.xml gets `title` re-derived from its own (already-renamed) filename on the next scan. Feeding that already-disambiguated name back in as `title` used to make titleHint() return the whole \"(already a hint)\" remainder WITH its wrapping parens intact, which idealFilename() then wrapped in another layer -- five real files on disk had compounded to five nested paren layers before this was caught. Running disambiguation twice in a row, feeding pass one's own output back in as the title, must converge to the same name, not grow another \"()\" layer")
    func disambiguationIsIdempotentAcrossRepeatedRuns() {
        let firstPass = ComicFileNaming.disambiguatedFilenames(for: [
            ComicFileNaming.NamingInput(id: 1, series: "Robin (TPB)", issueNumber: nil, title: "Robin v01 - Reborn",
                                         fileExtension: "cbr", year: nil, volume: nil, filePath: "/tmp/a.cbr"),
            ComicFileNaming.NamingInput(id: 2, series: "Robin (TPB)", issueNumber: nil, title: "Robin v02 - Triumphant",
                                         fileExtension: "cbr", year: nil, volume: nil, filePath: "/tmp/b.cbr"),
        ])
        #expect(firstPass[1] == "Robin (TPB) (Robin v01 - Reborn).cbr")

        // Simulate a rescan re-deriving `title` from the now-renamed file on disk (no ComicInfo.xml,
        // so title == filename minus extension) and running the renamer again.
        let rescannedTitle1 = String(firstPass[1]!.dropLast(".cbr".count))
        let rescannedTitle2 = String(firstPass[2]!.dropLast(".cbr".count))
        let secondPass = ComicFileNaming.disambiguatedFilenames(for: [
            ComicFileNaming.NamingInput(id: 1, series: "Robin (TPB)", issueNumber: nil, title: rescannedTitle1,
                                         fileExtension: "cbr", year: nil, volume: nil, filePath: "/tmp/a.cbr"),
            ComicFileNaming.NamingInput(id: 2, series: "Robin (TPB)", issueNumber: nil, title: rescannedTitle2,
                                         fileExtension: "cbr", year: nil, volume: nil, filePath: "/tmp/b.cbr"),
        ])
        #expect(secondPass[1] == firstPass[1])
        #expect(secondPass[2] == firstPass[2])
    }

    @Test("Real-world case: 651 issues of a folder matched GCD as \"The Amazing Spider-Man\", but a stretch of ~30 issues failed to match (GCD data gap) and kept the folder-derived fallback name \"ASM (1963)\" as their own gcdSeriesName is nil. The whole group should still resolve to the majority name")
    func canonicalSeriesNamesMajorityWinsOverMinorityMismatch() {
        var entries: [(publisher: String, series: String, gcdSeriesName: String?)] = []
        for _ in 1...651 { entries.append((publisher: "Marvel", series: "ASM (1963)", gcdSeriesName: "The Amazing Spider-Man")) }
        for _ in 1...30 { entries.append((publisher: "Marvel", series: "ASM (1963)", gcdSeriesName: nil)) }
        let canonical = ComicFileNaming.canonicalSeriesNames(for: entries)
        #expect(canonical["Marvel:ASM (1963)"] == "The Amazing Spider-Man")
    }

    @Test func canonicalSeriesNamesNoMatchesAtAllOmitsGroup() {
        let entries: [(publisher: String, series: String, gcdSeriesName: String?)] = [
            (publisher: "Marvel", series: "Unmatched Series", gcdSeriesName: nil),
            (publisher: "Marvel", series: "Unmatched Series", gcdSeriesName: nil),
        ]
        let canonical = ComicFileNaming.canonicalSeriesNames(for: entries)
        #expect(canonical["Marvel:Unmatched Series"] == nil, "a group with zero GCD matches should be omitted so callers fall back to each comic's own series field")
    }

    @Test func canonicalSeriesNamesDifferentPublisherOrSeriesKeptSeparate() {
        let entries: [(publisher: String, series: String, gcdSeriesName: String?)] = [
            (publisher: "Marvel", series: "X", gcdSeriesName: "Marvel X"),
            (publisher: "DC", series: "X", gcdSeriesName: "DC X"),
        ]
        let canonical = ComicFileNaming.canonicalSeriesNames(for: entries)
        #expect(canonical["Marvel:X"] == "Marvel X")
        #expect(canonical["DC:X"] == "DC X")
    }

    // MARK: - displaySeriesName (Layer 4: Display Information)

    private func fixtureComic(id: Int64, series: String, gcdSeriesName: String? = nil) -> Comic {
        Comic(id: id, title: "\(series) #1", filePath: "/tmp/\(id).cbz", publisher: "Marvel",
              character: nil, series: series, issueNumber: "1", pageCount: 20, writer: nil,
              penciller: nil, year: nil, volume: nil, format: nil, storyArc: nil, languageIso: nil,
              notes: nil, addedAt: "", deletedAt: nil, position: Int(id), fileHash: nil,
              gcdSeriesName: gcdSeriesName)
    }

    @Test("A group where most members have a real GCD match should display the canonical name, not whichever comic happens to be first")
    func displaySeriesNamePrefersCanonicalOverFirstComicsOwnValue() {
        let group = [
            fixtureComic(id: 1, series: "ASM (1963)", gcdSeriesName: nil),  // this one's own match failed
            fixtureComic(id: 2, series: "ASM (1963)", gcdSeriesName: "The Amazing Spider-Man"),
            fixtureComic(id: 3, series: "ASM (1963)", gcdSeriesName: "The Amazing Spider-Man"),
        ]
        #expect(ComicFileNaming.displaySeriesName(for: group) == "The Amazing Spider-Man")
    }

    @Test("With zero GCD matches anywhere in the group, falls back to the first comic's own series")
    func displaySeriesNameFallsBackWhenNoMatchesExist() {
        let group = [
            fixtureComic(id: 1, series: "Unmatched Series"),
            fixtureComic(id: 2, series: "Unmatched Series"),
        ]
        #expect(ComicFileNaming.displaySeriesName(for: group) == "Unmatched Series")
    }

    @Test func displaySeriesNameEmptyGroupReturnsEmptyString() {
        #expect(ComicFileNaming.displaySeriesName(for: []) == "")
    }

    @Test("A single comic with its own real GCD match uses it directly")
    func displaySeriesNameSingleComicWithMatch() {
        let group = [fixtureComic(id: 1, series: "ASM (1963)", gcdSeriesName: "The Amazing Spider-Man")]
        #expect(ComicFileNaming.displaySeriesName(for: group) == "The Amazing Spider-Man")
    }
}
