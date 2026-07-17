import Foundation
import CoreGraphics
import CryptoKit
import ZIPFoundation
#if os(macOS)
import AppKit
#endif

final class LibraryScanner: @unchecked Sendable {
    static let shared = LibraryScanner()
    private init() {}

    private let db = DatabaseManager.shared
    private let queue = DispatchQueue(label: "com.comicarc.scanner", qos: .utility)

    static let supportedExtensions: Set<String> = ["cbz", "cbr", "pdf", "jpg", "jpeg", "png"]
    private let supported = LibraryScanner.supportedExtensions

    struct ScanState: Sendable {
        var running = false; var total = 0; var done = 0; var added = 0
        var cancelled = false; var error: String?
    }

    private let stateLock = NSLock()
    private var _state = ScanState()

    var state: ScanState { stateLock.lock(); defer { stateLock.unlock() }; return _state }
    private func setState(_ block: (inout ScanState) -> Void) { stateLock.lock(); defer { stateLock.unlock() }; block(&_state) }
    func cancel() { setState { $0.cancelled = true } }

    func scan(libraryPath: String, onProgress: @escaping (ScanState) -> Void) {
        // Re-entrancy guard: ignore if already scanning
        guard !state.running else { return }
        queue.async { [self] in self._scan(libraryPath: libraryPath, onProgress: onProgress) }
    }

    private func _scan(libraryPath: String, onProgress: @escaping (ScanState) -> Void) {
        setState { $0 = ScanState(running: true) }

        let fm = FileManager.default

        // Verify library volume is actually reachable before touching the DB
        guard fm.fileExists(atPath: libraryPath),
              let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: libraryPath),
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            setState { $0.running = false; $0.error = "Library path is not accessible" }
            DispatchQueue.main.async { onProgress(self.state) }
            return
        }

        var allFiles: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if supported.contains(url.pathExtension.lowercased()) { allFiles.append(url) }
        }
        allFiles.sort { $0.path < $1.path }
        setState { $0.total = allFiles.count }

        var knownPaths  = db.knownPaths()
        var knownHashes = db.knownHashes()
        var added = 0

        // Batch inserts into chunks and commit each chunk as one transaction.
        // One transaction per file = O(n) fsyncs; one transaction per chunk = O(n/chunkSize).
        let chunkSize = 100
        var pending: [DatabaseManager.ComicInsert] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            db.batchInsert(pending)
            pending.removeAll()
        }

        for (i, url) in allFiles.enumerated() {
            if state.cancelled { break }
            let fp = url.path
            if !knownPaths.contains(fp) {
                let hash = fileHash(fp)
                if let h = hash, knownHashes.contains(h) {
                    db.updateFilePath(forHash: h, newPath: fp)
                    knownPaths.insert(fp)
                } else {
                    let meta = parseMeta(url: url, libraryPath: libraryPath)
                    pending.append(DatabaseManager.ComicInsert(
                        title: meta.title, filePath: fp, publisher: meta.publisher,
                        character: meta.character, series: meta.series,
                        issueNumber: meta.issueNumber, pageCount: pageCount(fp),
                        writer: meta.writer, penciller: meta.penciller,
                        year: meta.year, storyArc: meta.storyArc,
                        languageIso: meta.languageIso, fileHash: hash
                    ))
                    added += 1; knownPaths.insert(fp)
                    if let h = hash { knownHashes.insert(h) }
                    if pending.count >= chunkSize { flushPending() }
                }
            }
            let done = i + 1
            setState { $0.done = done; $0.added = added }
            if i % 25 == 0 { onProgress(state) }
        }
        flushPending()

        // Stale-path removal: only run if the library volume is still accessible.
        // Skipping on disconnect prevents mass soft-deletion when a drive unmounts temporarily.
        if !state.cancelled && fm.fileExists(atPath: libraryPath) {
            let stale = db.stalePaths().filter { !fm.fileExists(atPath: $0.path) }.map(\.id)
            if !stale.isEmpty { db.softDelete(stale) }
        }

        // Recovery pass: comics that were inserted with page_count=0 (corrupted at import time)
        // get a second chance now that the file may be readable.
        if !state.cancelled {
            for (id, path) in db.zeroPageCountPaths() {
                if state.cancelled { break }
                let count = pageCount(path)
                if count > 0 { db.updatePageCount(comicId: id, count: count) }
            }
        }

        setState { $0.running = false }
        onProgress(state)
    }

    func addSingle(url: URL, libraryPath: String) {
        let fp = url.path
        guard FileManager.default.fileExists(atPath: fp), supported.contains(url.pathExtension.lowercased()) else { return }
        let knownPaths = db.knownPaths()
        guard !knownPaths.contains(fp) else { return }
        let hash = fileHash(fp)
        if let h = hash, db.knownHashes().contains(h) { return }
        let meta = parseMeta(url: url, libraryPath: libraryPath)
        db.insert(comic: (
            title: meta.title, filePath: fp, publisher: meta.publisher,
            character: meta.character, series: meta.series,
            issueNumber: meta.issueNumber, pageCount: pageCount(fp),
            writer: meta.writer, penciller: meta.penciller,
            year: meta.year, storyArc: meta.storyArc,
            languageIso: meta.languageIso, fileHash: hash
        ))
    }

    func removeSingle(path: String) {
        let stale = db.stalePaths().filter { $0.path == path }.map(\.id)
        if !stale.isEmpty { db.softDelete(stale) }
    }

    // MARK: - File hash

    private func fileHash(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }
        let data = fh.readData(ofLength: 65536)
        guard !data.isEmpty else { return nil }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Page count

    func pageCount(_ path: String) -> Int {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "cbz":
            guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else { return 0 }
            return archive.filter { imageExts.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) && !$0.path.hasPrefix("__MACOSX") }.count
        case "pdf":
            guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
                  let pdf = CGPDFDocument(provider) else { return 0 }
            return pdf.numberOfPages
        case "jpg", "jpeg", "png": return 1
        case "cbr":
            #if os(macOS)
            return cbrPageCount(path)
            #else
            return 0
            #endif
        default: return 0
        }
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]
    private let imageExts = LibraryScanner.imageExtensions

    #if os(macOS)
    private func cbrPageCount(_ path: String) -> Int {
        guard which("unar") != nil else { return 0 }
        return cbrImageListing(path).count
    }

    private let cbrListingLock = NSLock()
    private var cbrListingCache: [String: [String]] = [:]

    private func cbrImageListing(_ path: String) -> [String] {
        cbrListingLock.lock()
        if let cached = cbrListingCache[path] { cbrListingLock.unlock(); return cached }
        cbrListingLock.unlock()
        guard let lsar = which("lsar") else { return [] }
        let listing = shell(lsar, args: [path])
        let images = listing.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { imageExts.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        cbrListingLock.lock()
        if cbrListingCache.count >= 500 { cbrListingCache.removeAll() }
        cbrListingCache[path] = images
        cbrListingLock.unlock()
        return images
    }
    #endif

    // MARK: - Metadata parsing

    private struct ComicMeta {
        var title: String; var publisher: String; var character: String?
        var series: String; var issueNumber: String?; var writer: String?
        var penciller: String?; var year: Int?; var storyArc: String?; var languageIso: String?
    }

    private func parseMeta(url: URL, libraryPath: String) -> ComicMeta {
        let ci = comicInfoXML(url: url)
        let filename = url.deletingPathExtension().lastPathComponent
        let (folderPublisher, folderCharacter, folderSeries) = folderComponents(url: url, libraryPath: libraryPath)
        let series = folderSeries ?? ci["Series"].map(normalizeSeriesName) ?? "General"
        let publisher = folderPublisher ?? ci["Publisher"].map(normalizePublisher) ?? "Unknown"
        let character: String?
        if let fc = folderCharacter { character = fc }
        else if let c = ci["Characters"], isCleanCharacterName(c) { character = c }
        else { character = nil }
        let issueNum = ci["IssueNumber"] ?? extractIssueNumber(from: filename)
        let title = filename
        return ComicMeta(title: title, publisher: publisher, character: character,
                         series: series, issueNumber: issueNum,
                         writer: ci["Writer"], penciller: ci["Penciller"],
                         year: ci["Year"].flatMap(Int.init),
                         storyArc: ci["StoryArc"], languageIso: ci["LanguageISO"])
    }

    func folderComponents(url: URL, libraryPath: String) -> (publisher: String?, character: String?, series: String?) {
        let libURL = URL(fileURLWithPath: libraryPath).standardized
        let dirURL = url.standardized.deletingLastPathComponent()
        var folders: [String] = []
        var cur = dirURL
        while cur.standardized.path.hasPrefix(libURL.path) && cur.standardized != libURL {
            folders.insert(cur.lastPathComponent, at: 0)
            cur = cur.deletingLastPathComponent()
        }
        switch folders.count {
        case 0: return (nil, nil, nil)
        case 1: return (nil, nil, folders[0])
        case 2: return (normalizePublisher(folders[0]), nil, folders[1])
        default:
            return (normalizePublisher(folders[0]), folders[1], folders[folders.count - 1])
        }
    }

    private func isCleanCharacterName(_ name: String) -> Bool {
        !name.contains(",") && !name.contains("[") && !name.contains("(") && name.count <= 60
    }

    func reparseAllMeta(libraryPath: String) {
        let comics = DatabaseManager.shared.allComicPaths()
        var updates: [(id: Int64, pub: String?, char: String?, ser: String?, title: String)] = []
        for (id, path) in comics {
            let url = URL(fileURLWithPath: path)
            let (pub, char, ser) = folderComponents(url: url, libraryPath: libraryPath)
            updates.append((id, pub, char, ser, url.deletingPathExtension().lastPathComponent))
        }
        DatabaseManager.shared.batchUpdateFolderMeta(updates)
    }

    private func comicInfoXML(url: URL) -> [String: String] {
        guard url.pathExtension.lowercased() == "cbz",
              let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil),
              let entry = archive.first(where: { $0.path.lowercased().hasSuffix("comicinfo.xml") }) else { return [:] }
        var data = Data()
        _ = try? archive.extract(entry, consumer: { data.append($0) })
        let keys: Set<String> = ["Series", "Title", "IssueNumber", "Publisher", "Writer", "Penciller",
                                  "Year", "StoryArc", "LanguageISO", "Characters"]
#if os(macOS)
        guard let root = try? XMLDocument(data: data).rootElement() else { return [:] }
        var result: [String: String] = [:]
        for key in keys {
            if let val = root.elements(forName: key).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty { result[key] = val }
        }
        return result
#else
        let delegate = _ComicInfoXMLParser(keys: keys)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result
#endif
    }

    private static let issuePatterns: [NSRegularExpression] = [
        "#(\\d+(?:\\.\\d+)?)", "(?:^|\\s|_)(\\d{1,4})(?:\\s|_|$)",
        "(?:issue|iss|no\\.?)\\s*(\\d+)", "v\\d+\\s*#(\\d+)"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    private func extractIssueNumber(from filename: String) -> String? {
        for regex in Self.issuePatterns {
            if let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
               let range = Range(match.range(at: 1), in: filename) { return String(filename[range]) }
        }
        return nil
    }

    private func normalizePublisher(_ raw: String) -> String {
        let map = ["dc": "DC", "marvel": "Marvel", "image": "Image", "dark horse": "Dark Horse",
                   "idw": "IDW", "boom": "BOOM!", "dynamite": "Dynamite"]
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return map[lower] ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeSeriesName(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Shell helpers (macOS only)

    #if os(macOS)
    private let whichLock = NSLock()
    private var whichCache: [String: String?] = [:]

    func which(_ name: String) -> String? {
        whichLock.lock()
        if let cached = whichCache[name] { whichLock.unlock(); return cached }
        whichLock.unlock()
        let resolved = resolveWhich(name)
        whichLock.lock(); whichCache[name] = resolved; whichLock.unlock()
        return resolved
    }

    private func resolveWhich(_ name: String) -> String? {
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent(name).path,
           FileManager.default.fileExists(atPath: bundled) { return bundled }
        let brewPaths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        if let found = brewPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) { return found }
        let result = shell("/usr/bin/which", args: [name])
        let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    @discardableResult
    func shell(_ executable: String, args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = Pipe()
        try? proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    #endif

    // MARK: - Page reading (for reader)

    func page(path: String, index: Int) -> PlatformImage? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "cbz": return cbzPage(path: path, index: index)
        case "pdf": return pdfPage(path: path, index: index)
        case "jpg", "jpeg", "png": return index == 0 ? PlatformImage.fromFile(path) : nil
        case "cbr":
            #if os(macOS)
            return cbrPage(path: path, index: index)
            #else
            return nil
            #endif
        default: return nil
        }
    }

    private func cbzPage(path: String, index: Int) -> PlatformImage? {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else { return nil }
        let images = archive
            .filter { imageExts.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) && !$0.path.hasPrefix("__MACOSX") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard index < images.count else { return nil }
        var data = Data()
        _ = try? archive.extract(images[index], consumer: { data.append($0) })
        return PlatformImage.fromData(data)
    }

    private func pdfPage(path: String, index: Int) -> PlatformImage? {
        guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
              let pdf = CGPDFDocument(provider),
              index < pdf.numberOfPages,
              let page = pdf.page(at: index + 1) else { return nil }
        return PlatformImage.renderPDFPage(page, scale: 1.5)
    }

    #if os(macOS)
    private func cbrPage(path: String, index: Int) -> PlatformImage? {
        guard let unar = which("unar") else { return nil }
        let images = cbrImageListing(path)
        guard index < images.count else { return nil }
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        shell(unar, args: ["-o", tmpDir.path, "-force-overwrite", path, images[index]])
        let enumerator = FileManager.default.enumerator(atPath: tmpDir.path)
        while let file = enumerator?.nextObject() as? String {
            if imageExts.contains(URL(fileURLWithPath: file).pathExtension.lowercased()) {
                return PlatformImage.fromFile(tmpDir.appendingPathComponent(file).path)
            }
        }
        return nil
    }
    #endif
}

#if !os(macOS)
private final class _ComicInfoXMLParser: NSObject, XMLParserDelegate {
    let keys: Set<String>
    var result: [String: String] = [:]
    private var currentElement: String?
    private var currentText = ""

    init(keys: Set<String>) { self.keys = keys }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if keys.contains(elementName) {
            currentElement = elementName
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement != nil { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if let key = currentElement, key == elementName {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result[key] = trimmed }
            currentElement = nil
        }
    }
}
#endif
