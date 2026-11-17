import Foundation
import CoreGraphics
import SwiftUI
import os

private let thumbnailLogger = Logger(subsystem: "com.comicarc", category: "thumbnailcache")

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private init() {
        cache.countLimit      = 500
        cache.totalCostLimit  = 80 * 1024 * 1024
    }

    private let cache = NSCache<NSNumber, PlatformImage>()
    private let queue = DispatchQueue(label: "com.comicarc.thumbs", qos: .utility, attributes: .concurrent)

    private let inflightLock = NSLock()
    // Each callback remembers the generation it registered under, so a late caller never receives a
    // stale result.
    private var inFlight: [Int64: [(gen: Int, globalGen: Int, callback: (PlatformImage?) -> Void)]] = [:]
    // Bumped by evict/setCustomCover/clearAll so an extraction still in flight can't overwrite the
    // newer value.
    private var generations: [Int64: Int] = [:]
    private var globalGeneration = 0

    private let accentColorLock = NSLock()
    private var accentColors: [Int64: Color] = [:]
    // Comics known to have no accent color, so they aren't re-read from disk every time.
    private var noAccentColorIds: Set<Int64> = []

    // Accent colors for series/character groups, keyed by the group's string key.
    private var groupAccentColors: [String: Color] = [:]
    private var noGroupAccentColorIds: Set<String> = []

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
        let gen = generations[comicId, default: 0]
        let startGlobalGen = globalGeneration
        if inFlight[comicId] != nil {
            inFlight[comicId]?.append((gen, startGlobalGen, completion))
            inflightLock.unlock()
            return
        }
        inFlight[comicId] = [(gen, startGlobalGen, completion)]
        inflightLock.unlock()

        queue.async { [self] in
            let diskURL = coversDir.appendingPathComponent("\(comicId).jpg")
            var result: PlatformImage?

            if let img = validatedDiskImage(at: diskURL) {
                cache.setObject(img, forKey: key, cost: img.byteSize)
                result = img
                // Backfills the accent color for covers cached before accent colors existed.
                if accentColorFromCache(comicId: comicId) == nil { saveAccentColor(for: comicId, from: img) }
            } else {
                try? FileManager.default.removeItem(at: diskURL)
                let img = extract(from: filePath)
                let thumb = img.flatMap { PlatformImage.resized(source: $0, to: thumbSize) }
                if let thumb {
                    inflightLock.lock()
                    let stillCurrent = generations[comicId, default: 0] == gen && globalGeneration == startGlobalGen
                    inflightLock.unlock()
                    // Only persist if nothing invalidated this comic while extracting.
                    if stillCurrent {
                        cache.setObject(thumb, forKey: key, cost: thumb.byteSize)
                        save(thumb, to: diskURL)
                        saveAccentColor(for: comicId, from: thumb)
                    }
                }
                result = thumb
            }
            inflightLock.lock()
            let callbacks = inFlight.removeValue(forKey: comicId) ?? []
            inflightLock.unlock()
            DispatchQueue.main.async { [self] in
                for entry in callbacks {
                    if entry.gen == gen && entry.globalGen == startGlobalGen {
                        entry.callback(result)
                    } else {
                        // This caller arrived after an invalidation, so request again rather than
                        // return stale data.
                        thumbnail(id: comicId, filePath: filePath, completion: entry.callback)
                    }
                }
            }
        }
    }

    /// Memory hits return immediately; otherwise the sidecar file is read off the main thread, and
    /// a comic with no color yet waits for its thumbnail (which computes the color).
    func accentColor(for comic: Comic, completion: @escaping (Color?) -> Void) {
        accentColorLock.lock()
        let memory = accentColors[comic.id]
        accentColorLock.unlock()
        if let memory { completion(memory); return }
        queue.async { [self] in
            if let color = accentColorFromCache(comicId: comic.id) {
                DispatchQueue.main.async { completion(color) }
                return
            }
            DispatchQueue.main.async { [self] in
                thumbnail(for: comic) { [weak self] _ in
                    completion(self?.accentColorFromCache(comicId: comic.id))
                }
            }
        }
    }

    func accentColorFromCache(comicId: Int64) -> Color? {
        accentColorLock.lock()
        if let cached = accentColors[comicId] { accentColorLock.unlock(); return cached }
        if noAccentColorIds.contains(comicId) { accentColorLock.unlock(); return nil }
        accentColorLock.unlock()
        let url = coversDir.appendingPathComponent("\(comicId).color")
        guard let hex = try? String(contentsOf: url, encoding: .utf8), let color = Color(hex: hex) else {
            accentColorLock.lock(); noAccentColorIds.insert(comicId); accentColorLock.unlock()
            return nil
        }
        accentColorLock.lock(); accentColors[comicId] = color; accentColorLock.unlock()
        return color
    }

    private func saveAccentColor(for comicId: Int64, from image: PlatformImage) {
        guard let color = image.averageColor(), let hex = color.toHexString() else { return }
        accentColorLock.lock(); accentColors[comicId] = color; noAccentColorIds.remove(comicId); accentColorLock.unlock()
        let url = coversDir.appendingPathComponent("\(comicId).color")
        try? hex.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A group's accent color, from its custom cover or representative comic, cached under the
    /// group key.
    func groupAccentColor(key: String, coverImagePath: String?, representativeComicId: Int64,
                           completion: @escaping (Color?) -> Void) {
        if let cached = groupAccentColorFromCache(key: key) { completion(cached); return }
        if let path = coverImagePath, let img = PlatformImage.fromFile(path) {
            saveGroupAccentColor(key: key, from: img)
            completion(groupAccentColorFromCache(key: key))
            return
        }
        if let cached = thumbnailFromCache(comicId: representativeComicId) {
            saveGroupAccentColor(key: key, from: cached)
            completion(groupAccentColorFromCache(key: key))
            return
        }
        guard let path = DatabaseManager.shared.filePath(forComicId: representativeComicId) else {
            completion(nil); return
        }
        thumbnail(id: representativeComicId, filePath: path) { [weak self] img in
            guard let self, let img else { completion(nil); return }
            self.saveGroupAccentColor(key: key, from: img)
            completion(self.groupAccentColorFromCache(key: key))
        }
    }

    func groupAccentColorFromCache(key: String) -> Color? {
        accentColorLock.lock()
        if let cached = groupAccentColors[key] { accentColorLock.unlock(); return cached }
        if noGroupAccentColorIds.contains(key) { accentColorLock.unlock(); return nil }
        accentColorLock.unlock()
        let url = coversDir.appendingPathComponent("\(safeGroupFileKey(key)).color")
        guard let hex = try? String(contentsOf: url, encoding: .utf8), let color = Color(hex: hex) else {
            accentColorLock.lock(); noGroupAccentColorIds.insert(key); accentColorLock.unlock()
            return nil
        }
        accentColorLock.lock(); groupAccentColors[key] = color; accentColorLock.unlock()
        return color
    }

    private func saveGroupAccentColor(key: String, from image: PlatformImage) {
        guard let color = image.averageColor(), let hex = color.toHexString() else { return }
        accentColorLock.lock(); groupAccentColors[key] = color; noGroupAccentColorIds.remove(key); accentColorLock.unlock()
        let url = coversDir.appendingPathComponent("\(safeGroupFileKey(key)).color")
        try? hex.write(to: url, atomically: true, encoding: .utf8)
    }

    private func safeGroupFileKey(_ key: String) -> String {
        key.components(separatedBy: .init(charactersIn: "/:")).joined(separator: "_")
    }

    /// Call when a group's custom cover changes.
    func evictGroupAccentColor(key: String) {
        accentColorLock.lock()
        groupAccentColors.removeValue(forKey: key)
        noGroupAccentColorIds.remove(key)
        accentColorLock.unlock()
        try? FileManager.default.removeItem(at: coversDir.appendingPathComponent("\(safeGroupFileKey(key)).color"))
    }

    private func evictAccentColor(_ comicId: Int64) {
        accentColorLock.lock()
        accentColors.removeValue(forKey: comicId)
        noAccentColorIds.remove(comicId)
        accentColorLock.unlock()
        try? FileManager.default.removeItem(at: coversDir.appendingPathComponent("\(comicId).color"))
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
        return PlatformImage.decodedFromURL(url)
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
                // A separate queue: thumbnailSync blocks waiting on `queue`, so it must not run on
                // it.
                DispatchQueue.global(qos: .utility).async { [self] in _ = thumbnailSync(for: comic); sema.signal(); group.leave() }
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
        evictAccentColor(comicId)
    }

    func clearAll() {
        inflightLock.lock()
        globalGeneration += 1
        inflightLock.unlock()
        cache.removeAllObjects()
        accentColorLock.lock()
        accentColors.removeAll(); noAccentColorIds.removeAll()
        groupAccentColors.removeAll(); noGroupAccentColorIds.removeAll()
        accentColorLock.unlock()
        if let files = try? FileManager.default.contentsOfDirectory(at: coversDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "jpg" || file.pathExtension == "color" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func setCustomCover(comicId: Int64, imageURL: URL) {
        guard let img = PlatformImage.fromURL(imageURL) else { return }
        setCustomCover(comicId: comicId, image: img)
    }

    func setCustomCover(comicId: Int64, image: PlatformImage) {
        guard let resized = PlatformImage.resized(source: image, to: thumbSize) else { return }
        inflightLock.lock()
        generations[comicId, default: 0] += 1
        inflightLock.unlock()
        let diskURL = coversDir.appendingPathComponent("\(comicId).jpg")
        save(resized, to: diskURL)
        cache.removeObject(forKey: NSNumber(value: comicId))
        saveAccentColor(for: comicId, from: resized)
    }

    func saveCustomGroupCover(groupName: String, publisher: String, imageURL: URL) -> String? {
        guard let img = PlatformImage.fromURL(imageURL),
              let resized = PlatformImage.resized(source: img, to: thumbSize) else { return nil }
        let key = "chargroup_\(publisher)_\(groupName)"
        let diskURL = coversDir.appendingPathComponent("\(safeGroupFileKey(key)).jpg")
        save(resized, to: diskURL)
        evictGroupAccentColor(key: key)
        return diskURL.path
    }

    func saveCustomSeriesCover(series: String, publisher: String, imageURL: URL) -> String? {
        guard let img = PlatformImage.fromURL(imageURL),
              let resized = PlatformImage.resized(source: img, to: thumbSize) else { return nil }
        let key = "series_\(publisher)_\(series)"
        let diskURL = coversDir.appendingPathComponent("\(safeGroupFileKey(key)).jpg")
        save(resized, to: diskURL)
        evictGroupAccentColor(key: key)
        return diskURL.path
    }

    func saveCustomRunCover(runId: Int64, imageURL: URL) -> String? {
        guard let img = PlatformImage.fromURL(imageURL),
              let resized = PlatformImage.resized(source: img, to: thumbSize) else { return nil }
        let diskURL = coversDir.appendingPathComponent("run_\(runId).jpg")
        save(resized, to: diskURL)
        return diskURL.path
    }

    func saveCoverFromComic(_ comic: Comic, destinationName: String) -> String? {
        _ = thumbnailSync(for: comic)
        let source = coversDir.appendingPathComponent("\(comic.id).jpg")
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let dest = coversDir.appendingPathComponent("\(destinationName).jpg")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            thumbnailLogger.error("Failed to copy cover for comic \(comic.id) to '\(destinationName)': \(error.localizedDescription)")
        }
        return FileManager.default.fileExists(atPath: dest.path) ? dest.path : nil
    }

    /// Runs on `queue`, so the blocking open is off the main thread.
    private func extract(from path: String) -> PlatformImage? {
        guard let document = try? ComicDocumentFactory.openSync(path: path),
              let source = try? document.pageSource(index: 0) else { return nil }
        defer { document.close() }
        // Decode straight at thumbnail size (3x) instead of full resolution.
        return PageDecoder.decode(source, maxPixelSize: Int(max(thumbSize.width, thumbSize.height) * 3))
    }

    private func save(_ image: PlatformImage, to url: URL) {
        guard let data = image.platformJPEGData(compressionFactor: 0.75) else {
            thumbnailLogger.error("Failed to JPEG-encode thumbnail for '\(url.lastPathComponent)'")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            thumbnailLogger.error("Failed to write thumbnail '\(url.lastPathComponent)' to disk: \(error.localizedDescription)")
        }
    }
}
