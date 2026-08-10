import Foundation

/// The decoded-page cache. Replaces the old `PageCache`'s hand-rolled dict+lock (capped at a
/// flat 30-entry count, with zero response to system memory pressure) with an `NSCache` budgeted
/// by actual decoded-image bytes -- pages range from ~200KB to tens of MB, so an entry-count cap
/// protects nothing predictable, and `NSCache` gets automatic pressure-driven eviction for free.
final class PageStore: @unchecked Sendable {
    static let shared = PageStore()
    private init() {
        cache.totalCostLimit = Self.defaultBudgetBytes
    }

    /// Starting budget to validate empirically against real device memory profiles (iPad base vs.
    /// Pro) -- not a number to treat as final. `NSCache` also evicts under system memory pressure
    /// on top of this soft budget, independent of it.
    private static let defaultBudgetBytes = 150 * 1024 * 1024

    private let cache = NSCache<NSString, PlatformImage>()
    private let queue = DispatchQueue(label: "com.comicarc.pagestore", qos: .userInitiated, attributes: .concurrent)

    private let lock = NSLock()
    private var generation: [Int64: Int] = [:]
    private var inFlight: [String: [(PlatformImage?) -> Void]] = [:]
    private var pendingPrefetches: [Int64: [DispatchWorkItem]] = [:]
    /// Keys inserted per comic, tracked only so `evict(comicId:)` can proactively drop that
    /// comic's pages instead of waiting on `NSCache`'s own (opaque, not necessarily comic-aware)
    /// eviction heuristics or the total-cost budget to eventually reclaim them.
    private var insertedKeys: [Int64: Set<String>] = [:]

    private func key(_ comicId: Int64, _ page: Int) -> String { "\(comicId):\(page)" }

    func get(comicId: Int64, page: Int) -> PlatformImage? {
        cache.object(forKey: key(comicId, page) as NSString)
    }

    private func currentGeneration(_ comicId: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        return generation[comicId] ?? 0
    }

    /// The primary request path. Cache hits deliver synchronously (no dispatch round-trip) so an
    /// already-warm page never visibly waits. A second request for a page already being decoded
    /// attaches its completion to the in-flight decode instead of starting a redundant one --
    /// the old `PageCache` had no such dedup, so a direct navigation racing a prefetch (or two
    /// fast taps) could decode the same page twice.
    func request(document: ComicDocument, comicId: Int64, page: Int, maxPixelSize: Int?, completion: @escaping (PlatformImage?) -> Void) {
        if let cached = get(comicId: comicId, page: page) { completion(cached); return }

        let k = key(comicId, page)
        lock.lock()
        if inFlight[k] != nil {
            inFlight[k]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[k] = [completion]
        lock.unlock()

        let gen = currentGeneration(comicId)
        queue.async { [self] in
            let image = decode(document: document, page: page, maxPixelSize: maxPixelSize)
            if let image { store(comicId: comicId, page: page, image: image, generation: gen) }
            lock.lock()
            let callbacks = inFlight.removeValue(forKey: k) ?? []
            lock.unlock()
            DispatchQueue.main.async { callbacks.forEach { $0(image) } }
        }
    }

    private func decode(document: ComicDocument, page: Int, maxPixelSize: Int?) -> PlatformImage? {
        guard let source = try? document.pageSource(index: page) else { return nil }
        return PageDecoder.decode(source, maxPixelSize: maxPixelSize)
    }

    private func store(comicId: Int64, page: Int, image: PlatformImage, generation requestGen: Int) {
        guard currentGeneration(comicId) == requestGen else { return }
        let k = key(comicId, page)
        cache.setObject(image, forKey: k as NSString, cost: image.byteSize)
        lock.lock(); insertedKeys[comicId, default: []].insert(k); lock.unlock()
    }

    /// Prefetch window shape, in pages, depends on reading mode -- continuous scroll can outrun a
    /// narrow forward window at real scroll velocity, so it gets a wider one; paged/spread modes
    /// go forward far more than back, but keep a small behind-window for the common accidental-
    /// overswipe case.
    enum PrefetchMode {
        case paged, spread, scroll
        var window: (behind: Int, ahead: Int) {
            switch self {
            case .paged:  return (1, 3)
            case .spread: return (1, 4)
            case .scroll: return (1, 6)
            }
        }
    }

    /// Skips PDFs entirely (rendering is comparatively expensive -- matches the old `PageCache`'s
    /// behavior), but PDF pages that do get rendered are still cached under the same rules once
    /// the user actually reaches them.
    func prefetch(document: ComicDocument, comicId: Int64, around page: Int, pageCount: Int, mode: PrefetchMode, maxPixelSize: Int?, isPDF: Bool) {
        guard !isPDF else { return }
        let (behind, ahead) = mode.window
        let gen = currentGeneration(comicId)

        var targets: [Int] = []
        if ahead > 0 { for offset in 1...ahead where page + offset < pageCount { targets.append(page + offset) } }
        if behind > 0 { for offset in 1...behind where page - offset >= 0 { targets.append(page - offset) } }

        var items: [DispatchWorkItem] = []
        for target in targets {
            guard get(comicId: comicId, page: target) == nil else { continue }
            let k = key(comicId, target)
            lock.lock()
            guard inFlight[k] == nil else { lock.unlock(); continue }
            lock.unlock()

            let item = DispatchWorkItem { [self] in
                guard currentGeneration(comicId) == gen else { return }
                if let image = decode(document: document, page: target, maxPixelSize: maxPixelSize) {
                    store(comicId: comicId, page: target, image: image, generation: gen)
                }
            }
            items.append(item)
            queue.async(execute: item)
        }

        lock.lock()
        pendingPrefetches[comicId, default: []].append(contentsOf: items)
        lock.unlock()
    }

    /// Cancels queued-but-not-yet-started prefetch work for a comic -- call before requesting a
    /// far jump's window (scrubber drag, page-number entry, filmstrip tap far from the current
    /// page), so a fast scrub doesn't leave a burst of decodes queued for pages already scrubbed
    /// past. `DispatchWorkItem.cancel()` prevents work that hasn't started from running at all;
    /// already-running decodes finish harmlessly (the result still gets cached, just wasn't
    /// urgently needed) rather than needing cooperative-cancellation checks inside a decode that's
    /// typically well under 50ms anyway.
    func cancelPrefetches(comicId: Int64) {
        lock.lock()
        let items = pendingPrefetches[comicId] ?? []
        pendingPrefetches[comicId] = []
        lock.unlock()
        items.forEach { $0.cancel() }
    }

    func evict(comicId: Int64) {
        lock.lock()
        generation[comicId, default: 0] += 1
        let items = pendingPrefetches[comicId] ?? []
        pendingPrefetches[comicId] = []
        let keys = insertedKeys.removeValue(forKey: comicId) ?? []
        lock.unlock()
        items.forEach { $0.cancel() }
        keys.forEach { cache.removeObject(forKey: $0 as NSString) }
    }
}
