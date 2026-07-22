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

    static var supportedExtensions: Set<String> {
        #if os(macOS)
        let cbrEnabled = UserDefaults.standard.object(forKey: "cbrEnabled") == nil
            || UserDefaults.standard.bool(forKey: "cbrEnabled")
        return cbrEnabled ? ["cbz", "cbr", "pdf", "jpg", "jpeg", "png"] : ["cbz", "pdf", "jpg", "jpeg", "png"]
        #else
        ["cbz", "pdf", "jpg", "jpeg", "png"]
        #endif
    }
    private var supported: Set<String> { Self.supportedExtensions }

    struct ScanState: Sendable {
        var running = false; var total = 0; var done = 0; var added = 0
        var removed = 0; var recovered = 0; var stillCorrupted = 0
        var cancelled = false; var error: String?
    }

    private let stateLock = NSLock()
    private var _state = ScanState()

    var state: ScanState { stateLock.lock(); defer { stateLock.unlock() }; return _state }
    private func setState(_ block: (inout ScanState) -> Void) { stateLock.lock(); defer { stateLock.unlock() }; block(&_state) }
    func cancel() { setState { $0.cancelled = true } }

    func runAfterCurrentWork(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    func scan(libraryPath: String, onProgress: @escaping (ScanState) -> Void) {
        guard !state.running else { return }
        queue.async { [self] in self._scan(libraryPath: libraryPath, onProgress: onProgress) }
    }

    private func _scan(libraryPath: String, onProgress: @escaping (ScanState) -> Void) {
        setState { $0 = ScanState(running: true) }

        let fm = FileManager.default

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

        let chunkSize = 100
        var pending: [DatabaseManager.ComicInsert] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            db.batchInsert(pending)
            pending.removeAll()
        }

        var touchedRawKeys: Set<String> = []
        var touchedEffectiveKeys: Set<String> = []

        func insertNewComic(url: URL, fp: String, hash: String?) {
            let meta = parseMeta(url: url, libraryPath: libraryPath)
            pending.append(DatabaseManager.ComicInsert(
                title: meta.title, filePath: fp, publisher: meta.publisher,
                character: meta.character, series: meta.series,
                issueNumber: meta.issueNumber, pageCount: pageCount(fp),
                writer: meta.writer, penciller: meta.penciller,
                year: meta.year, storyArc: meta.storyArc,
                languageIso: meta.languageIso, fileHash: hash,
                coverMonth: meta.coverMonth, coverDay: meta.coverDay,
                alternateNumber: meta.alternateNumber, storyArcNumber: meta.storyArcNumber,
                seriesGroup: meta.seriesGroup, comicInfoIssueNumber: meta.comicInfoIssueNumber,
                volume: meta.volume, format: meta.format, hasComicInfo: meta.hasComicInfo
            ))
            added += 1; knownPaths.insert(fp)
            if let hash { knownHashes.insert(hash) }
            touchedRawKeys.insert("\(meta.publisher):\(meta.series)")
            let effectiveSeries = meta.seriesGroup?.isEmpty == false ? meta.seriesGroup! : meta.series
            let effectiveKey = meta.volume?.isEmpty == false
                ? "\(meta.publisher):\(effectiveSeries):\(meta.volume!)" : "\(meta.publisher):\(effectiveSeries)"
            touchedEffectiveKeys.insert(effectiveKey)
            if pending.count >= chunkSize { flushPending() }
        }

        var anyRemoved = false

        for (i, url) in allFiles.enumerated() {
            if state.cancelled { break }
            let fp = url.path
            if !knownPaths.contains(fp) {
                let hash = fileHash(fp)
                if let h = hash, knownHashes.contains(h) {
                    if let existingPath = db.path(forHash: h), fm.fileExists(atPath: existingPath) {
                        insertNewComic(url: url, fp: fp, hash: h)
                    } else {
                        db.updateFilePath(forHash: h, newPath: fp)
                        knownPaths.insert(fp)
                    }
                } else {
                    insertNewComic(url: url, fp: fp, hash: hash)
                }
            }
            let done = i + 1
            setState { $0.done = done; $0.added = added }
            if i % 25 == 0 { onProgress(state) }
        }
        flushPending()

        if !state.cancelled && fm.fileExists(atPath: libraryPath) {
            let stale = db.stalePaths().filter { !fm.fileExists(atPath: $0.path) }.map(\.id)
            if !stale.isEmpty { db.softDelete(stale); anyRemoved = true }
            setState { $0.removed = stale.count }
        }

        if !state.cancelled {
            var recovered = 0
            var stillCorrupted = 0
            for (id, path) in db.zeroPageCountPaths() {
                if state.cancelled { break }
                let count = pageCount(path)
                if count > 0 { db.updatePageCount(comicId: id, count: count); recovered += 1 }
                else { db.incrementScanRetryCount(comicId: id); stillCorrupted += 1 }
            }
            setState { $0.recovered = recovered; $0.stillCorrupted = stillCorrupted }
        }

        let somethingChanged = added > 0 || anyRemoved
        if !state.cancelled && somethingChanged {
            db.seedMissingPositions()
            if anyRemoved {
                db.positionSpecialsChronologically()
                db.recomputeGCDMatches()
                db.autoPopulateSeriesLinksFromGCD()
                db.recomputeReadingOrder()
            } else {
                db.positionSpecialsChronologically(affectedGroupKeys: touchedRawKeys)
                db.recomputeGCDMatches(affectedGroupKeys: touchedEffectiveKeys)
                db.autoPopulateSeriesLinksFromGCD()
                db.recomputeReadingOrder(affectedGroupKeys: touchedEffectiveKeys)
            }
        }

        setState { $0.running = false }
        onProgress(state)
    }

    func addSingle(url: URL, libraryPath: String) {
        queue.sync {
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
    }

    func removeSingle(path: String) {
        let stale = db.stalePaths().filter { $0.path == path }.map(\.id)
        if !stale.isEmpty { db.softDelete(stale) }
    }

    private func fileHash(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }
        let prefix = fh.readData(ofLength: 65536)
        guard !prefix.isEmpty else { return nil }
        let size = fh.seekToEndOfFile()
        let tailStart = size > 65536 ? size - 65536 : 0
        fh.seek(toFileOffset: tailStart)
        let tail = fh.readDataToEndOfFile()
        var hasher = SHA256()
        hasher.update(data: prefix)
        hasher.update(data: withUnsafeBytes(of: size) { Data($0) })
        hasher.update(data: tail)
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

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

    private static let maxCBRSizeBytes: UInt64 = 5 * 1024 * 1024 * 1024

    private func cbrImageListing(_ path: String) -> [String] {
        cbrListingLock.lock()
        if let cached = cbrListingCache[path] { cbrListingLock.unlock(); return cached }
        cbrListingLock.unlock()
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        guard UInt64(size) <= Self.maxCBRSizeBytes else { return [] }
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

    private struct ComicMeta {
        var title: String; var publisher: String; var character: String?
        var series: String; var issueNumber: String?; var writer: String?
        var penciller: String?; var year: Int?; var coverMonth: Int?; var coverDay: Int?
        var storyArc: String?; var languageIso: String?
        var alternateNumber: String?; var storyArcNumber: String?; var seriesGroup: String?
        var comicInfoIssueNumber: String?
        var volume: String?
        var format: String?
        var hasComicInfo: Bool
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

        let issueNum = extractIssueNumber(from: filename) ?? ci["IssueNumber"]
        let title = filename

        let year = ci["Year"].flatMap(Int.init)
        let month = year != nil ? ci["Month"].flatMap(Int.init).flatMap { (1...12).contains($0) ? $0 : nil } : nil
        let day = month != nil ? ci["Day"].flatMap(Int.init).flatMap { (1...31).contains($0) ? $0 : nil } : nil
        return ComicMeta(title: title, publisher: publisher, character: character,
                         series: series, issueNumber: issueNum,
                         writer: ci["Writer"], penciller: ci["Penciller"],
                         year: year, coverMonth: month, coverDay: day,
                         storyArc: ci["StoryArc"], languageIso: ci["LanguageISO"],
                         alternateNumber: ci["AlternateNumber"], storyArcNumber: ci["StoryArcNumber"],
                         seriesGroup: ci["SeriesGroup"].map(normalizeSeriesName),
                         comicInfoIssueNumber: ci["IssueNumber"],
                         volume: ci["Volume"], format: ci["Format"],
                         hasComicInfo: !ci.isEmpty)
    }

    func folderComponents(url: URL, libraryPath: String) -> (publisher: String?, character: String?, series: String?) {
        let libURL = URL(fileURLWithPath: libraryPath).standardized

        let libPrefix = libURL.path.hasSuffix("/") ? libURL.path : libURL.path + "/"
        let dirURL = url.standardized.deletingLastPathComponent()
        var folders: [String] = []
        var cur = dirURL
        while cur.standardized.path.hasPrefix(libPrefix) && cur.standardized != libURL {
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

    func rehashAll() {
        let comics = DatabaseManager.shared.allComicPaths()
        for (id, path) in comics {
            guard let hash = fileHash(path) else { continue }
            DatabaseManager.shared.updateFileHash(id: id, hash: hash)
        }
    }

    func reparseAllMeta(libraryPath: String) {
        let comics = DatabaseManager.shared.allComicPaths()
        var updates: [(id: Int64, pub: String?, char: String?, ser: String?, title: String, issueNumber: String?)] = []
        for (id, path) in comics {
            let url = URL(fileURLWithPath: path)
            let (pub, char, ser) = folderComponents(url: url, libraryPath: libraryPath)
            let filename = url.deletingPathExtension().lastPathComponent
            updates.append((id, pub, char, ser, filename, extractIssueNumber(from: filename)))
        }
        DatabaseManager.shared.batchUpdateFolderMeta(updates)
        DatabaseManager.shared.resetScanRetryCounts()
    }

    private func comicInfoXML(url: URL) -> [String: String] {
        guard url.pathExtension.lowercased() == "cbz",
              let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil),
              let entry = archive.first(where: { $0.path.lowercased().hasSuffix("comicinfo.xml") }) else { return [:] }
        var data = Data()
        _ = try? archive.extract(entry, consumer: { data.append($0) })
        let keys: Set<String> = ["Series", "Title", "IssueNumber", "Publisher", "Writer", "Penciller",
                                  "Year", "Month", "Day", "StoryArc", "LanguageISO", "Characters",
                                  "AlternateNumber", "StoryArcNumber", "SeriesGroup", "Volume", "Format"]
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

        activeProcessLock.lock()
        activeProcess = proc
        activeProcessLock.unlock()
        defer { activeProcessLock.lock(); activeProcess = nil; activeProcessLock.unlock() }

        try? proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private let activeProcessLock = NSLock()
    private var activeProcess: Process?

    func terminateActiveProcess() {
        activeProcessLock.lock()
        let proc = activeProcess
        activeProcessLock.unlock()
        if proc?.isRunning == true { proc?.terminate() }
    }
    #endif

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

        shell(unar, args: ["-o", tmpDir.path, "-force-overwrite", path, "--", images[index]])
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
