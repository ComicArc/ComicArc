import Testing
@testable import ComicArc

/// `resumePage(for:)` is a pure function of a `Comic` (no DB access), so unlike most of the reader
/// -- which was previously untestable at all, being buried in SwiftUI view structs -- this is
/// directly exercisable with no fixtures or singletons involved.
struct ReadingProgressStoreTests {
    private func makeComic(pageCount: Int, progress: Int) -> Comic {
        Comic(id: 1, title: "Test", filePath: "/tmp/test.cbz", publisher: "Test Pub", character: nil,
              series: "Test Series", issueNumber: "1", pageCount: pageCount, writer: nil, penciller: nil,
              year: nil, volume: nil, format: nil, storyArc: nil, languageIso: nil, notes: nil,
              addedAt: "", deletedAt: nil, position: 0, fileHash: nil, progress: progress)
    }

    @Test func resumePageReturnsSavedProgressWhenInRange() {
        let comic = makeComic(pageCount: 20, progress: 7)
        #expect(ReadingProgressStore.resumePage(for: comic) == 7)
    }

    @Test func resumePageClampsToLastPageWhenProgressExceedsShrunkPageCount() {
        // A metadata refresh or a revival at the same path with a different file can leave a
        // saved position beyond the comic's current (now smaller) page count -- this is exactly
        // the scenario `ReaderSession.init`'s clamp exists for.
        let comic = makeComic(pageCount: 10, progress: 19)
        #expect(ReadingProgressStore.resumePage(for: comic) == 9)
    }

    @Test func resumePageClampsNegativeProgressToZero() {
        let comic = makeComic(pageCount: 20, progress: -3)
        #expect(ReadingProgressStore.resumePage(for: comic) == 0)
    }

    @Test func resumePageHandlesZeroPageCountWithoutGoingNegative() {
        let comic = makeComic(pageCount: 0, progress: 5)
        #expect(ReadingProgressStore.resumePage(for: comic) == 0)
    }

    @Test func resumePageAtExactlyLastPageStaysThere() {
        let comic = makeComic(pageCount: 20, progress: 19)
        #expect(ReadingProgressStore.resumePage(for: comic) == 19)
    }
}
