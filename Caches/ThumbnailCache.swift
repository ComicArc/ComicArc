import Foundation
import CoreGraphics
import ZIPFoundation

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private init() {

        cache.countLimit      = 500
        cache.totalCostLimit  = 80 * 1024 * 1024
    }

    private let cache = NSCache<NSNumber, PlatformImage>()
    private let queue = DispatchQueue(label: "com.comicarc.thumbs", qos: .utility, attributes: .concurrent)

    private let inflightLock = NSLock()
    private var inFlight: [Int64: [(PlatformImage?) -> Void]] = [:]
    // Guards against a race where a slow extraction (e.g. reading from a flaky/waking external
    // drive right before the file gets soft-deleted) is still in flight when evict() runs to
    // force a fresh read for a just-revived comic. Without this, the stale extraction finishes
    // AFTER the evict and writes its bad result right back to cache/disk, silently undoing the
    // eviction and re-corrupting the cover with no further trigger to fix it.
    private var generations: [Int64: Int] = [:]

    private let coversDir: URL = {
        let dir = DatabaseManager.dataDir.appendingPathComponent("covers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let thumbSize = CGSize(width: 160, height: 240)

    func thumbnail(for comic: Comic, completion: @escaping (PlatformImage?) -> Void) {
        thumbnail(id: comic.id, filePath: comic.filePath, completion: completion)
    }

    func thumbnail(id comicId: Int64, filePath: String, completion: @escaping (PlatformImage?) -> Void) {
        let key = NSNumber(value: comicId)
        if let cached = cache.object(forKey: key) { completion(cached); return }

        inflightLock.lock()
        if inFlight[comicId] != nil {
            inFlight[comicId]?.append(completion)
            inflightLock.unlock()
            return
        }
        inFlight[comicId] = [completion]
        let gen = generations[comicId, default: 0]
        inflightLock.unlock()

        queue.async { [self] in
            let diskURL = coversDir.appendingPathComponent("\(comicId).jpg")
            var result: PlatformImage?

            if let img = validatedDiskImage(at: diskURL) {
                cache.setObject(img, forKey: key, cost: img.byteSize)
                result = img
            } else {
                try? FileManager.default.removeItem(at: diskURL)
                let img = extract(from: filePath)
                let thumb = img.flatMap { PlatformImage.resized(source: $0, to: thumbSize) }
                if let thumb {
                    inflightLock.lock()
                    let stillCurrent = generations[comicId, default: 0] == gen
                    inflightLock.unlock()
                    // Only persist if nothing evicted this comic's thumbnail while this
                    // extraction was running -- an eviction mid-flight means the caller wanted
                    // a fresh read, and this result was computed from data that predates it.
                    if stillCurrent {
                        cache.setObject(thumb, forKey: key, cost: thumb.byteSize)
                        save(thumb, to: diskURL)
                    }
                }
                result = thumb
            }
            inflightLock.lock()
            let callbacks = inFlight.removeValue(forKey: comicId) ?? []
            inflightLock.unlock()
            DispatchQueue.main.async { for cb in callbacks { cb(result) } }
        }
    }

    func thumbnailFromCache(comicId: Int64) -> PlatformImage? {
        let key = NSNumber(value: comicId)
        if let cached = cache.object(forKey: key) { return cached }
        let diskURL = coversDir.appendingPathComponent("\(comicId).jpg")
        guard let img = validatedDiskImage(at: diskURL) else { return nil }
        cache.setObject(img, forKey: key, cost: img.byteSize)
        return img
    }

    func thumbnailSync(for comic: Comic) -> PlatformImage? {
        let sema = DispatchSemaphore(value: 0)
        var result: PlatformImage?
        thumbnail(for: comic) { img in result = img; sema.signal() }
        sema.wait()
        return result
    }

    private func validatedDiskImage(at url: URL) -> PlatformImage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? Int ?? 0) > 0 else { return nil }
        return PlatformImage.fromURL(url)
    }

    func prewarm(comics: [Comic]) {
        queue.async { [self] in
            let uncached = comics.filter {
                !FileManager.default.fileExists(atPath: coversDir.appendingPathComponent("\($0.id).jpg").path)
            }
            guard !uncached.isEmpty else { return }
            let sema = DispatchSemaphore(value: 4)
            let group = DispatchGroup()
            for comic in uncached {
                sema.wait(); group.enter()
                queue.async { [self] in _ = thumbnailSync(for: comic); sema.signal(); group.leave() }
            }
            group.wait()
        }
    }

    func evict(_ comicId: Int64) {
        inflightLock.lock()
        generations[comicId, default: 0] += 1
        inflightLock.unlock()
        cache.removeObject(forKey: NSNumber(value: comicId))
        let url = coversDir.appendingPathComponent("\(comicId).jpg")
        try? FileManager.default.removeItem(at: url)
    }

    func clearAll() {
        cache.removeAllObjects()
        if let files = try? FileManager.default.contentsOfDirectory(at: coversDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "jpg" { try? FileManager.default.removeItem(at: file) }
        }
    }

    func setCustomCover(comicId: Int64, imageURL: URL) {
        guard let img = PlatformImage.fromURL(imageURL) else { return }
        setCustomCover(comicId: comicId, image: img)
    }

    func setCustomCover(comicId: Int64, image: PlatformImage) {
        guard let resized = PlatformImage.resized(source: image, to: thumbSize) else { return }
        let diskURL = coversDir.appendingPathComponent("\(comicId).jpg")
        save(resized, to: diskURL)
        cache.removeObject(forKey: NSNumber(value: comicId))
    }

    func saveCustomGroupCover(groupName: String, publisher: String, imageURL: URL) -> String? {
        guard let img = PlatformImage.fromURL(imageURL),
              let resized = PlatformImage.resized(source: img, to: thumbSize) else { return nil }
        let safe = "chargroup_\(publisher)_\(groupName)"
            .components(separatedBy: .init(charactersIn: "/:"))
            .joined(separator: "_")
        let diskURL = coversDir.appendingPathComponent("\(safe).jpg")
        save(resized, to: diskURL)
        return diskURL.path
    }

    func saveCustomSeriesCover(series: String, publisher: String, imageURL: URL) -> String? {
        guard let img = PlatformImage.fromURL(imageURL),
              let resized = PlatformImage.resized(source: img, to: thumbSize) else { return nil }
        let safe = "series_\(publisher)_\(series)"
            .components(separatedBy: .init(charactersIn: "/:"))
            .joined(separator: "_")
        let diskURL = coversDir.appendingPathComponent("\(safe).jpg")
        save(resized, to: diskURL)
        return diskURL.path
    }

    func saveCustomRunCover(runId: Int64, imageURL: URL) -> String? {
        guard let img = PlatformImage.fromURL(imageURL),
              let resized = PlatformImage.resized(source: img, to: thumbSize) else { return nil }
        let diskURL = coversDir.appendingPathComponent("run_\(runId).jpg")
        save(resized, to: diskURL)
        return diskURL.path
    }

    func saveCustomListCover(listId: Int64, imageURL: URL) -> String? {
        guard let img = PlatformImage.fromURL(imageURL),
              let resized = PlatformImage.resized(source: img, to: thumbSize) else { return nil }
        let diskURL = coversDir.appendingPathComponent("list_\(listId).jpg")
        save(resized, to: diskURL)
        return diskURL.path
    }

    func saveCoverFromComic(_ comic: Comic, destinationName: String) -> String? {
        _ = thumbnailSync(for: comic)
        let source = coversDir.appendingPathComponent("\(comic.id).jpg")
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let dest = coversDir.appendingPathComponent("\(destinationName).jpg")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)
        return FileManager.default.fileExists(atPath: dest.path) ? dest.path : nil
    }

    private let imageExts = LibraryScanner.imageExtensions

    private func extract(from path: String) -> PlatformImage? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "cbz": return cbzCover(path)
        case "cbr": return LibraryScanner.shared.page(path: path, index: 0)
        case "pdf": return pdfCover(path)
        case "jpg", "jpeg", "png": return PlatformImage.fromFile(path)
        default: return nil
        }
    }

    private func cbzCover(_ path: String) -> PlatformImage? {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else { return nil }
        let entries = archive.filter {
            imageExts.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) && !$0.path.hasPrefix("__MACOSX")
        }
        guard let first = entries.min(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) else { return nil }

        guard first.uncompressedSize <= 50 * 1024 * 1024 else { return nil }
        var data = Data()
        data.reserveCapacity(Int(first.uncompressedSize))
        do {
            _ = try archive.extract(first, consumer: { data.append($0) })
        } catch {
            return nil
        }
        return PlatformImage.fromData(data)
    }

    private func pdfCover(_ path: String) -> PlatformImage? {
        guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
              let pdf = CGPDFDocument(provider),
              let page = pdf.page(at: 1) else { return nil }
        return PlatformImage.renderPDFPage(page, scale: 1.0)
    }

    private func save(_ image: PlatformImage, to url: URL) {
        guard let data = image.platformJPEGData(compressionFactor: 0.85) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
