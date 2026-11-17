import Foundation
import CoreGraphics
import AppKit

/// Limits how many expensive jobs run at once.
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ limit: Int) { available = limit }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Comic covers: memory, then `covers/<id>.jpg` on disk, then extracted from the comic's first
/// page. The disk layout matches earlier versions, so existing covers are reused.
actor CoverStore {
    static let shared = CoverStore()

    /// Long edge of generated covers, sized for the largest grid on a Retina display.
    static let coverPixels = 720
    // NSCache is thread-safe.
    private nonisolated(unsafe) let memory: NSCache<NSString, ImageBox> = {
        let c = NSCache<NSString, ImageBox>()
        c.totalCostLimit = 160 * 1024 * 1024
        return c
    }()
    private nonisolated(unsafe) let colors = NSCache<NSString, NSColor>()
    private var inflight: [String: Task<CGImage?, Never>] = [:]
    private var versions: [String: Int] = [:]
    private let extractions = AsyncLimiter(4)

    private nonisolated func diskURL(_ id: Int64) -> URL { AppPaths.covers.appendingPathComponent("\(id).jpg") }

    /// Instant memory lookup for views that want to avoid a placeholder flash.
    nonisolated func cached(_ id: Int64) -> CGImage? { memory.object(forKey: "c\(id)" as NSString)?.image }
    nonisolated func cachedFile(_ path: String) -> CGImage? { memory.object(forKey: "f\(path)" as NSString)?.image }
    nonisolated func cachedColor(_ id: Int64) -> NSColor? { colors.object(forKey: "c\(id)" as NSString) }

    func cover(id: Int64, path: String) async -> CGImage? {
        let key = "c\(id)"
        if let hit = memory.object(forKey: key as NSString) { return hit.image }
        if let running = inflight[key] { return await running.value }
        let disk = diskURL(id)
        let limiter = extractions
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            if FileManager.default.fileExists(atPath: disk.path),
               let image = ImageDecoder.decodeFile(disk, maxPixelSize: Self.coverPixels) { return image }
            await limiter.acquire()
            defer { Task { await limiter.release() } }
            guard let doc = try? Documents.open(path), doc.pageCount > 0, let page = try? doc.page(0),
                  let image = ImageDecoder.decode(page, maxPixelSize: Self.coverPixels) else { return nil }
            doc.close()
            if let data = ImageDecoder.jpegData(image) { try? data.write(to: disk, options: .atomic) }
            return image
        }
        return await finish(key, task)
    }

    /// A user-chosen cover image file (series, character or path covers).
    func image(atPath path: String) async -> CGImage? {
        let key = "f\(path)"
        if let hit = memory.object(forKey: key as NSString) { return hit.image }
        if let running = inflight[key] { return await running.value }
        let task = Task.detached(priority: .userInitiated) {
            ImageDecoder.decodeFile(URL(fileURLWithPath: path), maxPixelSize: Self.coverPixels)
        }
        return await finish(key, task)
    }

    private func finish(_ key: String, _ task: Task<CGImage?, Never>) async -> CGImage? {
        inflight[key] = task
        let version = versions[key, default: 0]
        let image = await task.value
        if inflight[key] == task { inflight[key] = nil }
        // Only cache if the cover wasn't replaced while this was loading.
        if let image, versions[key, default: 0] == version {
            memory.setObject(ImageBox(image), forKey: key as NSString, cost: ImageDecoder.byteCost(image))
        }
        return image
    }

    func accentColor(id: Int64, path: String) async -> NSColor? {
        if let hit = colors.object(forKey: "c\(id)" as NSString) { return hit }
        guard let image = await cover(id: id, path: path), let color = ImageDecoder.averageColor(image) else { return nil }
        colors.setObject(color, forKey: "c\(id)" as NSString)
        return color
    }

    /// Replaces a comic's cover with `image` (e.g. a page chosen in the cover picker).
    func setCover(_ image: CGImage, for id: Int64) {
        invalidate(id)
        if let data = ImageDecoder.jpegData(image) { try? data.write(to: diskURL(id), options: .atomic) }
        memory.setObject(ImageBox(image), forKey: "c\(id)" as NSString, cost: ImageDecoder.byteCost(image))
    }

    func invalidate(_ id: Int64) {
        let key = "c\(id)"
        versions[key, default: 0] += 1
        memory.removeObject(forKey: key as NSString)
        colors.removeObject(forKey: key as NSString)
        inflight[key] = nil
        try? FileManager.default.removeItem(at: diskURL(id))
    }

    func invalidateFile(_ path: String) {
        let key = "f\(path)"
        versions[key, default: 0] += 1
        memory.removeObject(forKey: key as NSString)
    }

    /// Copies a chosen image into the covers folder (downscaled) and returns its new path.
    nonisolated func importCustomImage(from url: URL, name: String) -> String? {
        guard let image = ImageDecoder.decodeFile(url, maxPixelSize: Self.coverPixels * 2),
              let data = ImageDecoder.jpegData(image, quality: 0.9) else { return nil }
        let dest = AppPaths.covers.appendingPathComponent("\(name).jpg")
        do { try data.write(to: dest, options: .atomic) } catch { return nil }
        return dest.path
    }

    func clearAll() {
        memory.removeAllObjects()
        colors.removeAllObjects()
        inflight.removeAll()
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: AppPaths.covers, includingPropertiesForKeys: nil)) ?? []
        where Int64(file.deletingPathExtension().lastPathComponent) != nil {
            try? fm.removeItem(at: file)
        }
    }
}
