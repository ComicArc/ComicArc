import Foundation
import CoreGraphics

/// Decoded pages for one open comic. Pages are decoded at the size they're displayed, kept in a
/// memory-budgeted cache, and prefetched ahead in reading direction so a page turn finds its
/// image already decoded.
actor PageRenderer {
    let document: ComicDocument
    nonisolated let pageCount: Int

    private struct Key: Hashable { let page: Int; let size: Int }
    private var cache: [Key: ImageBox] = [:]
    private var order: [Key] = []            // least recently used first
    private var bytes = 0
    private let budget = 500 * 1024 * 1024
    private var inflight: [Key: Task<CGImage?, Never>] = [:]
    private var prefetchTasks: [Task<Void, Never>] = []
    private var aspectCache: [Int: CGFloat] = [:]

    init(document: ComicDocument) {
        self.document = document
        pageCount = document.pageCount
    }

    /// Sizes are bucketed so small window resizes reuse already-decoded pages.
    nonisolated static func bucket(_ pixels: Int?) -> Int {
        guard let pixels else { return 0 }
        return min(ImageDecoder.maxDimension, max(512, Int((Double(pixels) / 256).rounded(.up)) * 256))
    }

    /// Instant cache hit check (any decode at least this large).
    func cachedImage(_ page: Int, maxPixel: Int?) -> CGImage? {
        let wanted = Self.bucket(maxPixel)
        let hits = cache.filter { $0.key.page == page && ($0.key.size == 0 || ($0.key.size >= wanted && wanted != 0)) }
        guard let best = hits.min(by: { $0.key.size < $1.key.size }) else { return nil }
        touch(best.key)
        return best.value.image
    }

    func image(_ page: Int, maxPixel: Int?) async -> CGImage? {
        guard page >= 0, page < pageCount else { return nil }
        if let hit = cachedImage(page, maxPixel: maxPixel) { return hit }
        let key = Key(page: page, size: Self.bucket(maxPixel))
        if let running = inflight[key] { return await running.value }
        let doc = document
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = try? doc.page(page) else { return nil }
            return ImageDecoder.decode(source, maxPixelSize: key.size == 0 ? nil : key.size)
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { store(image, key) }
        return image
    }

    /// Width / height of a page, read from the file header (no decode).
    func aspectRatio(_ page: Int) -> CGFloat? {
        if let hit = aspectCache[page] { return hit }
        guard let source = try? document.page(page), let size = ImageDecoder.pixelSize(source), size.height > 0 else { return nil }
        let ratio = size.width / size.height
        aspectCache[page] = ratio
        return ratio
    }

    /// Decodes upcoming pages in the background, cancelling the previous prefetch window.
    func prefetch(_ pages: [Int], maxPixel: Int?) {
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks = pages.filter { $0 >= 0 && $0 < pageCount }.map { page in
            Task(priority: .utility) { [weak self] in
                guard !Task.isCancelled else { return }
                _ = await self?.image(page, maxPixel: maxPixel)
            }
        }
    }

    func thumbnail(_ page: Int) async -> CGImage? { await image(page, maxPixel: 300) }

    func close() {
        prefetchTasks.forEach { $0.cancel() }
        cache.removeAll(); order.removeAll(); bytes = 0
        document.close()
    }

    private func store(_ image: CGImage, _ key: Key) {
        let cost = ImageDecoder.byteCost(image)
        cache[key] = ImageBox(image)
        touch(key)
        bytes += cost
        while bytes > budget, let oldest = order.first {
            order.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { bytes -= ImageDecoder.byteCost(removed.image) }
        }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
