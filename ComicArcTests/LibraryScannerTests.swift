import Testing
import Foundation
@testable import ComicArc

struct LibraryScannerTests {
    private let scanner = LibraryScanner.shared

    @Test func extractYearMatchesParentheticalYear() {
        #expect(scanner.extractYear(from: "The_Amazing_Spider-Man_(2014)_Issue_#10") == 2014)
    }

    @Test("Open-ended ongoing series year is matched (GCD/ComicVine convention for a series with no end year yet)")
    func extractYearMatchesOpenEndedOngoingSeriesYear() {
        #expect(scanner.extractYear(from: "The_Amazing_Spider-Man_(2015-)_#1-4") == 2015)
    }

    @Test func extractYearReturnsNilWhenNoYearPresent() {
        #expect(scanner.extractYear(from: "Batman #441") == nil)
    }

    @Test("\"(1)\" and \"(2nd Printing)\" must never be mistaken for a year", arguments: [
        "Batman Annual (1)",
        "Batman #1 (2nd Printing)",
    ])
    func extractYearDoesNotMatchShortParentheticalNumbers(filename: String) {
        #expect(scanner.extractYear(from: filename) == nil)
    }

    @Test("A \"(YYYY-YYYY)\" range isn't handled by the simple ongoing-series pattern -- returning nil (no guess) here is correct; a wrong guess would be worse than no signal at all")
    func extractYearDoesNotMatchAYearRange() {
        #expect(scanner.extractYear(from: "Watchmen (1986-1987) #1") == nil)
    }

    @Test func extractYearPicksFirstMatchWhenMultiplePresent() {
        #expect(scanner.extractYear(from: "Reprint (2020) of Original (1990) #1") == 2020)
    }

    // MARK: - matchingRoot (multi-folder library support)

    @Test func matchingRootFindsTheOwningRootAmongSeveral() {
        let roots = ["/Volumes/NAS/Comics", "/Users/me/Comics", "/Users/me/Downloads/MoreComics"]
        #expect(scanner.matchingRoot(for: "/Users/me/Comics/Batman/Batman #1.cbz", in: roots) == "/Users/me/Comics")
    }

    @Test func matchingRootReturnsNilWhenNoRootMatches() {
        #expect(scanner.matchingRoot(for: "/Volumes/Other/Batman #1.cbz", in: ["/Users/me/Comics"]) == nil)
    }

    @Test("Roots aren't expected to nest, but the longest match wins as a cheap safety net if they somehow do")
    func matchingRootPrefersLongestMatchWhenRootsNest() {
        let roots = ["/Users/me/Comics", "/Users/me/Comics/Marvel"]
        #expect(scanner.matchingRoot(for: "/Users/me/Comics/Marvel/Batman #1.cbz", in: roots) == "/Users/me/Comics/Marvel")
    }

    @Test func matchingRootExactPathMatchesTheRootItself() {
        #expect(scanner.matchingRoot(for: "/Users/me/Comics", in: ["/Users/me/Comics"]) == "/Users/me/Comics")
    }

    @Test("A root without a trailing slash must not falsely prefix-match a sibling folder with a similar name")
    func matchingRootDoesNotFalselyMatchASimilarlyNamedSibling() {
        #expect(scanner.matchingRoot(for: "/Users/me/ComicsArchive/Batman #1.cbz", in: ["/Users/me/Comics"]) == nil)
    }
}
