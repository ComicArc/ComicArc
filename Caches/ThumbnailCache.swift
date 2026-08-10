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
    // Each pending callback remembers the generation pair current when IT was registered, not
    // just when the in-flight extraction it coalesced onto started. Without this, a caller that
    // arrives after evict()/setCustomCover()/clearAll() invalidates an already-running extraction
    // would still be handed that extraction's stale result once it finishes -- the generation
    // check below only stops the stale result from being persisted, not from being delivered.
    private var inFlight: [Int64: [(gen: Int, globalGen: Int, callback: (PlatformImage?) -> Void)]] = [:]
    // Guards against a race where a slow extraction (e.g. reading from a flaky/waking external
    // drive right before the file gets soft-deleted) is still in flight when evict()/
    // setCustomCover() runs to force a fresh read for a just-revived comic or a user-picked
    // cover. Without this, the stale extraction finishes AFTER and writes its bad result right
    // back to cache/disk, silently undoing the eviction/override with no further trigger to fix
    // it. `globalGeneration` covers clearAll(), which invalidates every comic at once.
    private var generations: [Int64: Int] = [:]
    private var globalGeneration = 0

    private let accentColorLock = NSLock()
    private var accentColors: [Int64: Color] = [:]
    // Without this, a comic with no color sidecar (extraction failed, or genuinely no color)
    // re-hits disk on every single appearance forever -- there was previously no way to
    // distinguish "never looked up" from "looked up, nothing there".
    private var noAccentColorIds: Set<Int64> = []

    // Same idea as accentColors/noAccentColorIds above, but keyed by a group's own stable string
    // key (e.g. "chargroup_DC_Batman") instead of a single comic id -- a series/character
    // "identity color" for the art-driven grid/header treatment, computed from the group's
    // representative cover and surviving that representative comic changing.
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
                // Backfills the accent-color sidecar for a cover cached before this feature
                // existed -- without this, every pre-existing thumbnail would need an eviction
                // just to ever get an accent color.
                if accentColorFromCache(comicId: comicId) == nil { saveAccentColor(for: comicId, from: img) }
            } else {
                try? FileManager.default.removeItem(at: diskURL)
                let img = extract(from: filePath)
                let thumb = img.flatMap { PlatformImage.resized(source: $0, to: thumbSize) }
                if let thumb {
                    inflightLock.lock()
                    let stillCurrent = generations[comicId, default: 0] == gen && globalGeneration == startGlobalGen
                    inflightLock.unlock()
                    // Only persist if nothing evicted/overrode this comic's thumbnail (or cleared
                    // the whole cache) while this extraction was running -- such a change mid-
                    // flight means the caller wanted a fresh read or a specific override, and
                    // this result was computed from data that predates it.
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
                        // This caller registered after something invalidated the extraction that
                        // just ran -- handing back `result` would silently deliver stale data.
                        // Re-request instead: an immediate cache/disk hit if the invalidator
                        // already wrote a fresh value (e.g. setCustomCover), otherwise a fresh
                        // extraction.
                        thumbnail(id: comicId, filePath: filePath, completion: entry.callback)
                    }
                }
            }
        }
    }

    /// Mirrors `thumbnail(for:completion:)` -- the accent color is computed alongside the
    /// thumbnail itself (see `saveAccentColor`), so getting it just means waiting for whatever
    /// already produces or fetches that thumbnail, then reading the color back out of cache.
    func accentColor(for comic: Comic, completion: @escaping (Color?) -> Void) {
        if let cached = accentColorFromCache(comicId: comic.id) { completion(cached); return }
        thumbnail(for: comic) { [weak self] _ in
            completion(self?.accentColorFromCache(comicId: comic.id))
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

    /// Series/character "identity color" -- same average-color technique as `accentColor(for:)`
    /// above, but derived from a group's representative cover (custom cover image if one's been
    /// set, else the group's representative comic) and cached under the group's own key so the
    /// color is stable even if that representative comic later changes.
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

    /// Called whenever a group's custom cover changes -- without this, the identity color
    /// computed from the *old* cover would keep being served from cache/disk indefinitely.
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
                // Dispatch onto a separate global queue, not `queue` itself: thumbnailSync
                // blocks its thread on a semaphore waiting for thumbnail(...)'s own queue.async
                // to finish -- submitting that blocking wait back onto the very queue it's
                // waiting on is a GCD anti-pattern that can starve the pool during a large
                // library's prewarm instead of a clean, bounded fan-out.
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

    func saveCustomTierListCover(tierListId: Int64, imageURL: URL) -> String? {
        guard let img = PlatformImage.fromURL(imageURL),
              let resized = PlatformImage.resized(source: img, to: thumbSize) else { return nil }
        let diskURL = coversDir.appendingPathComponent("tierlist_\(tierListId).jpg")
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

    /// Called from inside `queue.async` (see `thumbnail(for:completion:)` above), so the
    /// synchronous open (real work for CBR: a subprocess extraction, shared with reading-time
    /// extraction via `CBRExtractionCache`) is safe here, off the main thread.
    private func extract(from path: String) -> PlatformImage? {
        guard let document = try? ComicDocumentFactory.openSync(path: path),
              let source = try? document.pageSource(index: 0) else { return nil }
        defer { document.close() }
        return PageDecoder.decode(source, maxPixelSize: nil)
    }

    private func save(_ image: PlatformImage, to url: URL) {
        guard let data = image.platformJPEGData(compressionFactor: 0.85) else {
            thumbnailLogger.error("Failed to JPEG-encode thumbnail for '\(url.lastPathComponent)'")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // The one real diagnostic point for "why are my thumbnails not showing up" -- a
            // failure here (disk full, permissions) previously left zero trace anywhere.
            thumbnailLogger.error("Failed to write thumbnail '\(url.lastPathComponent)' to disk: \(error.localizedDescription)")
        }
    }
}
