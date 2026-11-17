import Foundation
import CoreGraphics
import ZIPFoundation

enum DocumentError: Error { case cannotOpen, pageOutOfRange, pageTooLarge, toolMissing }

/// A page before decoding.
enum PageSource: @unchecked Sendable {
    case data(Data)
    case pdf(CGPDFPage)
}

/// An open comic file. Opened once per reading session, then asked for pages by index.
protocol ComicDocument: AnyObject, Sendable {
    var pageCount: Int { get }
    func page(_ index: Int) throws -> PageSource
    func close()
}

enum Documents {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "avif"]
    static let comicExtensions: Set<String> = ["cbz", "zip", "cbr", "rar", "pdf"]
    static let libraryExtensions: Set<String> = ["cbz", "cbr", "pdf", "jpg", "jpeg", "png"]

    /// Opening can block (archive listing, CBR extraction), so never call this on the main thread.
    static func open(_ path: String) throws -> ComicDocument {
        switch (path as NSString).pathExtension.lowercased() {
        case "cbz", "zip": return try ZipDocument(path: path)
        case "cbr", "rar": return try RarDocument(path: path)
        case "pdf": return try PDFComicDocument(path: path)
        case let ext where imageExtensions.contains(ext): return ImageFileDocument(path: path)
        default: throw DocumentError.cannotOpen
        }
    }

    /// Page count without keeping the document open (scanner).
    static func pageCount(_ path: String) -> Int {
        guard let doc = try? open(path) else { return 0 }
        defer { doc.close() }
        return doc.pageCount
    }

    static func isPage(_ name: String) -> Bool {
        let lower = name.lowercased()
        let file = (lower as NSString).lastPathComponent
        return imageExtensions.contains((lower as NSString).pathExtension)
            && !lower.hasPrefix("__macosx") && !file.hasPrefix(".")
    }
}

/// CBZ. ZIPFoundation's `Archive` wraps one file handle, so extraction is serialized; decoding
/// happens outside the lock.
final class ZipDocument: ComicDocument, @unchecked Sendable {
    private let archive: Archive
    private let entries: [Entry]
    private let lock = NSLock()
    private static let maxPageBytes: UInt64 = 200 * 1024 * 1024

    init(path: String) throws {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else {
            throw DocumentError.cannotOpen
        }
        self.archive = archive
        entries = archive.filter { $0.type == .file && Documents.isPage($0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var pageCount: Int { entries.count }

    func page(_ index: Int) throws -> PageSource {
        guard entries.indices.contains(index) else { throw DocumentError.pageOutOfRange }
        let entry = entries[index]
        guard entry.uncompressedSize <= Self.maxPageBytes else { throw DocumentError.pageTooLarge }
        var data = Data(capacity: Int(entry.uncompressedSize))
        try lock.withLock { _ = try archive.extract(entry) { data.append($0) } }
        return .data(data)
    }

    func close() {}
}

final class PDFComicDocument: ComicDocument, @unchecked Sendable {
    private let pdf: CGPDFDocument

    init(path: String) throws {
        guard let pdf = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else { throw DocumentError.cannotOpen }
        self.pdf = pdf
    }

    var pageCount: Int { pdf.numberOfPages }

    func page(_ index: Int) throws -> PageSource {
        guard let page = pdf.page(at: index + 1) else { throw DocumentError.pageOutOfRange }
        return .pdf(page)
    }

    func close() {}
}

final class ImageFileDocument: ComicDocument, @unchecked Sendable {
    private let url: URL
    init(path: String) { url = URL(fileURLWithPath: path) }
    var pageCount: Int { 1 }
    func page(_ index: Int) throws -> PageSource {
        guard index == 0 else { throw DocumentError.pageOutOfRange }
        return .data(try Data(contentsOf: url, options: .mappedIfSafe))
    }
    func close() {}
}

/// CBR, via the bundled `unar`. The archive is extracted once into a temporary folder that a
/// small cache keeps around, so reopening a recent CBR is instant.
final class RarDocument: ComicDocument, @unchecked Sendable {
    private let files: [URL]

    init(path: String) throws {
        guard let files = RarExtractionCache.shared.pages(for: path), !files.isEmpty else { throw DocumentError.cannotOpen }
        self.files = files
    }

    var pageCount: Int { files.count }

    func page(_ index: Int) throws -> PageSource {
        guard files.indices.contains(index) else { throw DocumentError.pageOutOfRange }
        return .data(try Data(contentsOf: files[index], options: .mappedIfSafe))
    }

    func close() {}
}

final class RarExtractionCache: @unchecked Sendable {
    static let shared = RarExtractionCache()
    private let lock = NSLock()
    private var entries: [(path: String, dir: URL, files: [URL])] = []
    private static let keep = 3

    func pages(for path: String) -> [URL]? {
        if let hit = lock.withLock({ entries.first { $0.path == path }?.files }) { return hit }
        guard let unar = ExternalTool.path("unar") else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("comicarc-cbr-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        _ = ExternalTool.run(unar, ["-quiet", "-no-directory", "-force-overwrite", "-output-directory", dir.path, path])
        let found = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { Documents.isPage($0.path.replacingOccurrences(of: dir.path + "/", with: "")) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var evicted: [URL] = []
        lock.withLock {
            entries.append((path, dir, found))
            while entries.count > Self.keep { evicted.append(entries.removeFirst().dir) }
        }
        evicted.forEach { try? FileManager.default.removeItem(at: $0) }
        return found
    }

    func clear() {
        let dirs = lock.withLock { () -> [URL] in defer { entries.removeAll() }; return entries.map(\.dir) }
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

/// Finds and runs the command-line tools bundled for CBR support.
enum ExternalTool {
    private static let cache = NSCache<NSString, NSString>()

    static func path(_ name: String) -> String? {
        if let hit = cache.object(forKey: name as NSString) { return hit as String }
        let candidates = [Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name).path,
                          "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"].compactMap { $0 }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        cache.setObject(found as NSString, forKey: name as NSString)
        return found
    }

    /// Runs a tool to completion and returns its standard output. Output is read while the
    /// process runs, so a large listing can't fill the pipe and hang it.
    @discardableResult
    static func run(_ executable: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
