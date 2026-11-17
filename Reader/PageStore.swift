import Foundation
import CoreGraphics

/// Decoded-page cache: an `NSCache` budgeted by decoded bytes, with automatic eviction under memory
/// pressure.
final class PageStore: @unchecked Sendable {
    static let shared = PageStore()
    private init() {
        cache.totalCostLimit = Self.defaultBudgetBytes
    }

    /// Soft budget; `NSCache` also evicts under system memory pressure.
    private static let defaultBudgetBytes = 150 * 1024 * 1024

    private let cache = NSCache<NSString, PlatformImage>()
    private let queue = DispatchQueue(label: "com.comicarc.pagestore", qos: .userInitiated, attributes: .concurrent)

    private let lock = NSLock()
    private var generation: [Int64: Int] = [:]
    private var inFlight: [String: [(PlatformImage?) -> Void]] = [:]
    private var pendingPrefetches: [Int64: [DispatchWorkItem]] = [:]
    /// Keys per comic, so `evict(comicId:)` can drop a comic's pages immediately.
    private var insertedKeys: [Int64: Set<String>] = [:]
    /// The resolution each entry was decoded at (`Int.max` = full). A hit only counts if it's at
    /// least as sharp as requested.
    private var decodedPixelSize: [String: Int] = [:]

    private func key(_ comicId: Int64, _ page: Int) -> String { "\(comicId):\(page)" }

    private func sufficientlyCached(_ k: String, maxPixelSize: Int?) -> PlatformImage? {
        guard let image = cache.object(forKey: k as NSString) else { return nil }
        let requested = maxPixelSize ?? Int.max
        lock.lock()
        let cachedResolution = decodedPixelSize[k] ?? 0
        lock.unlock()
        return cachedResolution >= requested ? image : nil
    }

    private func currentGeneration(_ comicId: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        return generation[comicId] ?? 0
    }

    /// Main request path. Cache hits return synchronously; a request for a page already being
    /// decoded joins that decode.
    func request(document: ComicDocument, comicId: Int64, page: Int, maxPixelSize: Int?, completion: @escaping (PlatformImage?) -> Void) {
        let k = key(comicId, page)
        if let cached = sufficientlyCached(k, maxPixelSize: maxPixelSize) { completion(cached); return }

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
            if let image { store(comicId: comicId, page: page, image: image, generation: gen, maxPixelSize: maxPixelSize) }
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

    private func store(comicId: Int64, page: Int, image: PlatformImage, generation requestGen: Int, maxPixelSize: Int?) {
        guard currentGeneration(comicId) == requestGen else { return }
        let k = key(comicId, page)
        cache.setObject(image, forKey: k as NSString, cost: image.byteSize)
        lock.lock()
        insertedKeys[comicId, default: []].insert(k)
        decodedPixelSize[k] = maxPixelSize ?? Int.max
        lock.unlock()
    }

    /// Prefetch window per reading mode: wider for continuous scroll, mostly forward for paged
    /// modes.
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

    /// PDFs aren't prefetched (rendering is expensive), but rendered PDF pages are cached normally.
    func prefetch(document: ComicDocument, comicId: Int64, around page: Int, pageCount: Int, mode: PrefetchMode, maxPixelSize: Int?, isPDF: Bool) {
        guard !isPDF else { return }
        let (behind, ahead) = mode.window
        let gen = currentGeneration(comicId)

        var targets: [Int] = []
        if ahead > 0 { for offset in 1...ahead where page + offset < pageCount { targets.append(page + offset) } }
        if behind > 0 { for offset in 1...behind where page - offset >= 0 { targets.append(page - offset) } }

        var items: [DispatchWorkItem] = []
        for target in targets {
            let k = key(comicId, target)
            guard sufficientlyCached(k, maxPixelSize: maxPixelSize) == nil else { continue }
            lock.lock()
            guard inFlight[k] == nil else { lock.unlock(); continue }
            lock.unlock()

            let item = DispatchWorkItem { [self] in
                guard currentGeneration(comicId) == gen else { return }
                if let image = decode(document: document, page: target, maxPixelSize: maxPixelSize) {
                    store(comicId: comicId, page: target, image: image, generation: gen, maxPixelSize: maxPixelSize)
                }
            }
            items.append(item)
            queue.async(execute: item)
        }

        lock.lock()
        pendingPrefetches[comicId, default: []].append(contentsOf: items)
        lock.unlock()
    }

    /// Cancels queued prefetches for a comic, e.g. before a far jump. Decodes already running
    /// finish.
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
        keys.forEach { decodedPixelSize.removeValue(forKey: $0) }
        lock.unlock()
        items.forEach { $0.cancel() }
        keys.forEach { cache.removeObject(forKey: $0 as NSString) }
    }
}

/// Decodes a page at roughly the size it will be shown, which keeps decode time and memory low for
/// large scans.
enum PageDecoder {
    /// `maxPixelSize`: target long edge in pixels, or nil for full resolution. Always capped at
    /// `maxDecodedPixelDimension`.
    static func decode(_ source: PageSource, maxPixelSize: Int?) -> PlatformImage? {
        let cappedSize = min(maxPixelSize ?? maxDecodedPixelDimension, maxDecodedPixelDimension)
        switch source {
        case .imageData(let data):
            guard let cg = safeCGImage(from: data, maxPixelSize: cappedSize) else { return nil }
            return PlatformImage.fromCGImage(cg)
        case .pdfPage(let page):
            let box = page.getBoxRect(.mediaBox)
            let longEdge = max(box.width, box.height, 1)
            let scale: CGFloat
            if maxPixelSize != nil {
                scale = max(1.0, CGFloat(cappedSize) / longEdge)
            } else {
                scale = PlatformImage.pdfRenderScale
            }
            return PlatformImage.renderPDFPage(page, scale: scale)
        }
    }
}

/// Filmstrip thumbnails, cached separately from `PageStore` so scrubbing never evicts the pages
/// being read.
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()
    private init() { cache.countLimit = 300 }

    private let cache = NSCache<NSString, PlatformImage>()
    private let queue = DispatchQueue(label: "com.comicarc.thumbnailstore", qos: .utility, attributes: .concurrent)
    private static let thumbnailMaxPixelSize = 220

    private func key(_ comicId: Int64, _ page: Int) -> NSString { "\(comicId):\(page)" as NSString }

    /// Reuses the session's open document and decodes straight at thumbnail size.
    func thumbnail(document: ComicDocument, comicId: Int64, page: Int, completion: @escaping (PlatformImage?) -> Void) {
        let k = key(comicId, page)
        if let cached = cache.object(forKey: k) { completion(cached); return }
        queue.async { [self] in
            let thumb: PlatformImage?
            if let source = try? document.pageSource(index: page) {
                thumb = PageDecoder.decode(source, maxPixelSize: Self.thumbnailMaxPixelSize)
            } else {
                thumb = nil
            }
            if let thumb { cache.setObject(thumb, forKey: k) }
            DispatchQueue.main.async { completion(thumb) }
        }
    }
}
