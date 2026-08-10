import Foundation

/// Filmstrip/scrubber thumbnails -- deliberately separate from `PageStore`: the filmstrip can be
/// scrubbed across an entire comic while reading, and sharing the reading-page cache would evict
/// the actual current/prefetched pages the paged reader just loaded, causing visible reload/
/// flicker when the user returns to reading. Entry-count capped (unlike `PageStore`'s byte
/// budget) since thumbnails are small and uniform in size, so count alone is a fine proxy.
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()
    private init() { cache.countLimit = 300 }

    private let cache = NSCache<NSString, PlatformImage>()
    private let queue = DispatchQueue(label: "com.comicarc.thumbnailstore", qos: .utility, attributes: .concurrent)
    /// Long-edge pixel size -- matches the old 120x180 display size with headroom for Retina.
    private static let thumbnailMaxPixelSize = 220

    private func key(_ comicId: Int64, _ page: Int) -> NSString { "\(comicId):\(page)" as NSString }

    /// `document` is the caller's already-open `ComicDocument` for this comic (the reading
    /// session's own document, in practice) -- reusing it instead of opening a second document
    /// just for a thumbnail avoids a redundant CBZ listing/CBR extraction for a comic already
    /// open. Decodes via `PageDecoder`'s target-size-aware path rather than decoding a full page
    /// and resizing it down after the fact.
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
