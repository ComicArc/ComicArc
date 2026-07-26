import Foundation
import CoreGraphics

/// Small, separate cache for filmstrip-scrubber thumbnails, keyed by (comicId, page).
/// Deliberately distinct from `PageCache`: the filmstrip can be scrubbed across an entire
/// comic while reading, and sharing the 30-entry reading-page cache would evict the actual
/// current/prefetched pages the paged reader just loaded, causing visible reload/flicker
/// when the user returns to reading. Thumbnails are also decoded at a much smaller size, so
/// a far larger cache stays cheap in memory.
final class PageThumbnailCache: @unchecked Sendable {
    static let shared = PageThumbnailCache()
    private init() {
        cache.countLimit = 300
    }

    private let cache = NSCache<NSString, PlatformImage>()
    private let queue = DispatchQueue(label: "com.comicarc.pagethumbs", qos: .utility, attributes: .concurrent)
    private let thumbSize = CGSize(width: 120, height: 180)

    private func key(_ comicId: Int64, _ page: Int) -> NSString { "\(comicId):\(page)" as NSString }

    func thumbnail(comic: Comic, page: Int, completion: @escaping (PlatformImage?) -> Void) {
        let k = key(comic.id, page)
        if let cached = cache.object(forKey: k) { completion(cached); return }
        queue.async { [self] in
            let full = LibraryScanner.shared.page(path: comic.filePath, index: page)
            let thumb = full.flatMap { PlatformImage.resized(source: $0, to: thumbSize) }
            if let thumb { cache.setObject(thumb, forKey: k) }
            DispatchQueue.main.async { completion(thumb) }
        }
    }
}
