import Testing
import Foundation
@testable import ComicArc

/// `folderComponents` (publisher/character/group/series from a comic's folder depth relative to
/// its library root) previously had zero coverage -- `LibraryScannerTests.swift` only exercises
/// the year-extraction regex. This is real, load-bearing logic: get it wrong and every comic in a
/// user's library files under the wrong publisher/series. Pure path-string parsing, no DB or
/// filesystem access, so safe to call directly on `LibraryScanner.shared`.
struct LibraryScannerFolderParsingTests {
    private let scanner = LibraryScanner.shared
    private let libraryRoot = "/Users/test/Comics"

    private func components(_ relativePath: String) -> (publisher: String?, character: String?, group: String?, series: String?) {
        let url = URL(fileURLWithPath: "\(libraryRoot)/\(relativePath)")
        return scanner.folderComponents(url: url, libraryPath: libraryRoot)
    }

    @Test func fileDirectlyInLibraryRootHasNoFolderStructure() {
        let result = components("Batman #1.cbz")
        #expect(result.publisher == nil)
        #expect(result.character == nil)
        #expect(result.group == nil)
        #expect(result.series == nil)
    }

    @Test func oneLevelDeepIsSeriesOnly() {
        let result = components("Batman/Batman #1.cbz")
        #expect(result.publisher == nil)
        #expect(result.character == nil)
        #expect(result.group == nil)
        #expect(result.series == "Batman")
    }

    @Test func twoLevelsDeepIsPublisherThenSeries() {
        let result = components("DC/Batman/Batman #1.cbz")
        #expect(result.publisher == "DC")
        #expect(result.character == nil)
        #expect(result.group == nil)
        #expect(result.series == "Batman")
    }

    @Test func threeLevelsDeepIsPublisherCharacterSeries() {
        let result = components("DC/Batman/Batman (2016)/Batman #1.cbz")
        #expect(result.publisher == "DC")
        #expect(result.character == "Batman")
        #expect(result.group == nil)
        #expect(result.series == "Batman (2016)")
    }

    @Test func fourLevelsDeepInsertsAGroupBetweenCharacterAndSeries() {
        let result = components("DC/Batman/Batman (Modern)/Batman (2016)/Batman #1.cbz")
        #expect(result.publisher == "DC")
        #expect(result.character == "Batman")
        #expect(result.group == "Batman (Modern)")
        #expect(result.series == "Batman (2016)")
    }

    @Test func fiveOrMoreLevelsJoinsEveryMiddleFolderIntoOneGroupString() {
        let result = components("DC/Batman/Era A/Era B/Batman (2016)/Batman #1.cbz")
        #expect(result.group == "Era A / Era B")
        #expect(result.series == "Batman (2016)")
    }

    @Test func knownPublisherAliasesAreNormalized() {
        // normalizePublisher lowercases-and-maps a small known set ("dc" -> "DC", etc.) --
        // real-world folders are inconsistently cased ("Dc", "DC", "dc").
        let result = components("dc/Batman/Batman #1.cbz")
        #expect(result.publisher == "DC")
    }

    @Test func matchingRootPicksTheLongestPrefixAmongMultipleLibraryRoots() {
        let roots = ["/Users/test/Comics", "/Users/test/Comics/Imports"]
        let path = "/Users/test/Comics/Imports/DC/Batman/Batman #1.cbz"
        #expect(scanner.matchingRoot(for: path, in: roots) == "/Users/test/Comics/Imports")
    }

    @Test func matchingRootReturnsNilWhenPathIsOutsideEveryRoot() {
        let roots = ["/Users/test/Comics"]
        #expect(scanner.matchingRoot(for: "/Users/other/Comics/Batman #1.cbz", in: roots) == nil)
    }
}
