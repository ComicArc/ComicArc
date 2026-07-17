import Foundation

final class PageCache: @unchecked Sendable {
    static let shared = PageCache()
    private init() {}

    private let lock  = NSLock()
    private var store = [String: PlatformImage]()
    private var order = [String]()
    private let maxEntries = 30

    private let queue = DispatchQueue(label: "com.comicarc.pages", qos: .userInitiated, attributes: .concurrent)

    private func key(_ comicId: Int64, _ page: Int) -> String { "\(comicId):\(page)" }

    func get(comicId: Int64, page: Int) -> PlatformImage? {
        lock.lock(); defer { lock.unlock() }
        let k = key(comicId, page)
        guard let img = store[k] else { return nil }
        if let idx = order.firstIndex(of: k) { order.remove(at: idx); order.append(k) }
        return img
    }

    func set(comicId: Int64, page: Int, image: PlatformImage) {
        lock.lock(); defer { lock.unlock() }
        let k = key(comicId, page)
        if store[k] == nil && store.count >= maxEntries, let oldest = order.first {
            store.removeValue(forKey: oldest); order.removeFirst()
        }
        if let idx = order.firstIndex(of: k) { order.remove(at: idx) }
        order.append(k); store[k] = image
    }

    func load(comic: Comic, page: Int, completion: @escaping (PlatformImage?) -> Void) {
        if let cached = get(comicId: comic.id, page: page) { completion(cached); return }
        queue.async { [self] in
            let img = LibraryScanner.shared.page(path: comic.filePath, index: page)
            if let img { set(comicId: comic.id, page: page, image: img) }
            DispatchQueue.main.async { completion(img) }
        }
    }

    func prefetch(comic: Comic, around page: Int, count: Int = 3) {
        guard comic.fileExtension != "pdf" else { return }
        for offset in 1...count {
            let target = page + offset
            guard target < comic.pageCount else { break }
            guard get(comicId: comic.id, page: target) == nil else { continue }
            queue.async { [self] in
                let img = LibraryScanner.shared.page(path: comic.filePath, index: target)
                if let img { set(comicId: comic.id, page: target, image: img) }
            }
        }
    }

    func evict(comicId: Int64) {
        lock.lock(); defer { lock.unlock() }
        let prefix = "\(comicId):"
        for k in store.keys where k.hasPrefix(prefix) { store.removeValue(forKey: k) }
        order.removeAll { $0.hasPrefix(prefix) }
    }
}
