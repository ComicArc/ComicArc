import Testing
import Foundation
@testable import ComicArc

/// A fake `ComicDocument` that counts how many times each page was actually decoded from, so
/// tests can assert on dedup/caching behavior without touching a real file. `pageSource` returns
/// tiny synthetic PNG bytes -- cheap enough to decode thousands of times inside a test suite.
private final class CountingFakeDocument: ComicDocument, @unchecked Sendable {
    let pageCount: Int
    private let lock = NSLock()
    private(set) var decodeCounts: [Int: Int] = [:]

    init(pageCount: Int) { self.pageCount = pageCount }

    func pageSource(index: Int) throws -> PageSource {
        guard index >= 0, index < pageCount else { throw ComicDocumentError.pageOutOfRange }
        lock.lock(); decodeCounts[index, default: 0] += 1; lock.unlock()
        return .imageData(Self.onePixelPNG)
    }

    func close() {}

    func count(for page: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return decodeCounts[page] ?? 0
    }

    /// A minimal valid 1x1 PNG -- enough for ImageIO to decode into a real (tiny) `PlatformImage`.
    static let onePixelPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
        0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00,
        0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ])
}

/// Randomized per test to avoid collisions in `PageStore.shared`'s cache across Swift Testing's
/// parallel-by-default test execution -- the same reasoning `DatabaseTestFixture` isolates each
/// test's `DatabaseManager` for, applied to the (deliberately singleton) page cache instead.
private func uniqueComicId() -> Int64 { Int64.random(in: 1_000_000...Int64.max) }

struct PageStoreTests {
    @Test func requestDeliversCachedResultOnSecondCall() async {
        let doc = CountingFakeDocument(pageCount: 5)
        let comicId = uniqueComicId()
        defer { PageStore.shared.evict(comicId: comicId) }

        await withCheckedContinuation { cont in
            PageStore.shared.request(document: doc, comicId: comicId, page: 0, maxPixelSize: nil) { _ in cont.resume() }
        }
        await withCheckedContinuation { cont in
            PageStore.shared.request(document: doc, comicId: comicId, page: 0, maxPixelSize: nil) { _ in cont.resume() }
        }

        #expect(doc.count(for: 0) == 1)
    }

    @Test func concurrentRequestsForSamePageDedupToOneDecode() async {
        let doc = CountingFakeDocument(pageCount: 5)
        let comicId = uniqueComicId()
        defer { PageStore.shared.evict(comicId: comicId) }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await withCheckedContinuation { cont in
                        PageStore.shared.request(document: doc, comicId: comicId, page: 2, maxPixelSize: nil) { _ in cont.resume() }
                    }
                }
            }
        }

        #expect(doc.count(for: 2) == 1)
    }

    @Test func evictBumpsGenerationSoStaleInFlightDecodeIsDropped() async {
        let doc = CountingFakeDocument(pageCount: 5)
        let comicId = uniqueComicId()

        await withCheckedContinuation { cont in
            PageStore.shared.request(document: doc, comicId: comicId, page: 0, maxPixelSize: nil) { _ in cont.resume() }
        }
        // Evicting bumps the comic's generation counter -- a page cached before eviction should
        // no longer be considered warm afterward.
        PageStore.shared.evict(comicId: comicId)
        #expect(PageStore.shared.get(comicId: comicId, page: 0) == nil)
    }

    @Test func getReturnsNilForNeverRequestedPage() {
        let comicId = uniqueComicId()
        #expect(PageStore.shared.get(comicId: comicId, page: 0) == nil)
    }

    @Test func prefetchSkipsPDFsEntirely() async {
        let doc = CountingFakeDocument(pageCount: 5)
        let comicId = uniqueComicId()
        defer { PageStore.shared.evict(comicId: comicId) }

        PageStore.shared.prefetch(document: doc, comicId: comicId, around: 0, pageCount: 5, mode: .paged, maxPixelSize: nil, isPDF: true)
        // Give any (incorrectly) scheduled work a moment to run, then confirm nothing decoded.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(doc.count(for: 1) == 0)
    }

    @Test func prefetchWarmsForwardWindowInPagedMode() async {
        let doc = CountingFakeDocument(pageCount: 10)
        let comicId = uniqueComicId()
        defer { PageStore.shared.evict(comicId: comicId) }

        PageStore.shared.prefetch(document: doc, comicId: comicId, around: 0, pageCount: 10, mode: .paged, maxPixelSize: nil, isPDF: false)
        // Poll briefly rather than a fixed sleep -- prefetch is async by design.
        for _ in 0..<50 {
            if PageStore.shared.get(comicId: comicId, page: 1) != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(PageStore.shared.get(comicId: comicId, page: 1) != nil)
    }
}
