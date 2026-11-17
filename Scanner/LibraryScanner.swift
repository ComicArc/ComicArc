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

    let db = DatabaseManager.shared
    let queue = DispatchQueue(label: "com.comicarc.scanner", qos: .utility)

    static var supportedExtensions: Set<String> {
        #if os(macOS)
        ["cbz", "cbr", "pdf", "jpg", "jpeg", "png"]
        #else
        ["cbz", "pdf", "jpg", "jpeg", "png"]
        #endif
    }
    private var supported: Set<String> { Self.supportedExtensions }

    /// Extensions importable as single files; loose images only count inside a scanned folder.
    static let importableExtensions: Set<String> = ["cbz", "cbr", "pdf"]

    struct ScanState: Sendable {
        var running = false; var total = 0; var done = 0; var added = 0
        var removed = 0; var recovered = 0; var stillCorrupted = 0
        var cancelled = false; var error: String?
        /// Ids soft-deleted by this scan, so their Spotlight entries can be removed.
        var removedIds: [Int64] = []
        /// Whether anything changed, so callers can skip follow-up work after a no-op scan.
        var changed = false
    }

    private let stateLock = NSLock()
    private var _state = ScanState()
    /// Progress observers for the scan in flight, including callers who asked while it was already
    /// running.
    private var observers: [(ScanState) -> Void] = []

    var state: ScanState { stateLock.lock(); defer { stateLock.unlock() }; return _state }
    private func setState(_ block: (inout ScanState) -> Void) { stateLock.lock(); defer { stateLock.unlock() }; block(&_state) }
    func cancel() { setState { $0.cancelled = true } }

    /// Notifies every observer on the main thread; clears the list once the scan finishes.
    private func notifyObservers() {
        stateLock.lock()
        let currentObservers = observers
        let currentState = _state
        if !currentState.running { observers.removeAll() }
        stateLock.unlock()
        DispatchQueue.main.async { currentObservers.forEach { $0(currentState) } }
    }

    func runAfterCurrentWork(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    /// The configured library root containing `path` (longest match), or nil if it isn't under one.
    func matchingRoot(for path: String, in roots: [String]) -> String? {
        roots.filter { root in
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path == root || path.hasPrefix(prefix)
        }.max { $0.count < $1.count }
    }

    func scan(libraryPaths: [String], onProgress: @escaping (ScanState) -> Void) {
        // Check-and-set under one lock so two near-simultaneous callers can't both start a scan.
        var shouldRun = false
        stateLock.lock()
        if !_state.running { _state = ScanState(running: true); shouldRun = true }
        observers.append(onProgress)
        stateLock.unlock()
        guard shouldRun else { return }
        queue.async { [self] in self._scan(libraryPaths: libraryPaths) }
    }

    private func _scan(libraryPaths: [String]) {
        runImportPriorityAudit()

        let fm = FileManager.default
        let reachableRoots = libraryPaths.filter { fm.fileExists(atPath: $0) }
        guard !reachableRoots.isEmpty else {
            setState { $0.running = false; $0.error = "None of your configured library folders are accessible" }
            notifyObservers()
            return
        }

        var allFiles: [URL] = []
        for root in reachableRoots {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if supported.contains(url.pathExtension.lowercased()) { allFiles.append(url) }
            }
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

        func insertNewComic(url: URL, fp: String, hash: String?) {
            // This path's soft-deleted comic is about to be revived; evict its possibly-bad cached
            // cover.
            if let staleId = db.softDeletedComicId(atPath: fp) {
                ThumbnailCache.shared.evict(staleId)
            }
            let root = matchingRoot(for: fp, in: reachableRoots) ?? reachableRoots.first ?? ""
            let meta = parseMeta(url: url, libraryPath: root)
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
                volume: meta.volume, format: meta.format, hasComicInfo: meta.hasComicInfo,
                comicInfoSeries: meta.comicInfoSeries, comicInfoPublisher: meta.comicInfoPublisher,
                folderSeries: meta.folderSeries, folderPublisher: meta.folderPublisher, folderGroup: meta.folderGroup,
                seriesSource: meta.seriesSource, publisherSource: meta.publisherSource,
                issueNumberSource: meta.issueNumberSource
            ))
            added += 1; knownPaths.insert(fp)
            if let hash { knownHashes.insert(hash) }
            if pending.count >= chunkSize { flushPending() }
        }

        var anyRemoved = false
        var movedComics: [(id: Int64, url: URL)] = []

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
                        if let id = db.idForHash(h) { movedComics.append((id, url)) }
                    }
                } else {
                    insertNewComic(url: url, fp: fp, hash: hash)
                }
            }
            let done = i + 1
            setState { $0.done = done; $0.added = added }
            if i % 25 == 0 { notifyObservers() }
        }
        flushPending()

        if !movedComics.isEmpty {
            // A moved/renamed file keeps its identity via its hash; re-derive its folder metadata
            // from the new path.
            var updates: [(id: Int64, pub: String?, char: String?, ser: String?, title: String, issueNumber: String?, year: Int?, group: String?)] = []
            for (id, url) in movedComics {
                let root = matchingRoot(for: url.path, in: libraryPaths) ?? ""
                let (pub, char, group, ser) = folderComponents(url: url, libraryPath: root)
                let filename = url.deletingPathExtension().lastPathComponent
                updates.append((id, pub, char, ser, filename, extractIssueNumber(from: filename), extractYear(from: filename), group))
            }
            db.batchUpdateFolderMeta(updates)
        }

        if !state.cancelled && !reachableRoots.isEmpty {
            let active = db.stalePaths()
            // Only comics under a currently reachable root are checked for staleness.
            let checkable = active.filter { comic in
                guard let root = matchingRoot(for: comic.path, in: libraryPaths) else { return false }
                return reachableRoots.contains(root)
            }
            let stale = checkable.filter { !fm.fileExists(atPath: $0.path) }.map(\.id)
            // Safety net: a flaky drive can make many files look missing at once, so a mass
            // disappearance is not treated as deletion.
            let suspiciouslyLarge = checkable.count >= 20 && stale.count > checkable.count / 2
            if !stale.isEmpty && !suspiciouslyLarge {
                db.softDelete(stale, reason: "missing"); anyRemoved = true
                stale.forEach { ThumbnailCache.shared.evict($0) }
                setState { $0.removed = stale.count; $0.removedIds = stale }
            } else if suspiciouslyLarge {
                setState { $0.error = "Skipped removing \(stale.count) of \(checkable.count) comics that looked missing -- this usually means the drive was slow to wake up or briefly disconnected, not that the files are actually gone. Rescan once the drive is fully available to confirm." }
            }
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

        let somethingChanged = added > 0 || anyRemoved || !movedComics.isEmpty
        setState { $0.changed = somethingChanged }
        if !state.cancelled && somethingChanged {
            db.seedMissingPositions()
        }

        setState { $0.running = false }
        notifyObservers()
    }

    enum AddSingleResult: Equatable {
        case added
        case movedOrRenamed
        case alreadyInLibrary
        case fileNotFound
        case unsupportedFormat
    }

    @discardableResult
    func addSingle(url: URL, libraryRoots: [String]) -> AddSingleResult {
        queue.sync {
            let fm = FileManager.default
            let fp = url.path
            guard fm.fileExists(atPath: fp) else { return .fileNotFound }
            guard supported.contains(url.pathExtension.lowercased()) else { return .unsupportedFormat }
            let knownPaths = db.knownPaths()
            guard !knownPaths.contains(fp) else { return .alreadyInLibrary }
            let hash = fileHash(fp)
            // A hash match is either a move/rename (original path gone: update in place) or a real
            // duplicate (original still exists: insert).
            if let h = hash, db.knownHashes().contains(h) {
                if let existingPath = db.path(forHash: h), fm.fileExists(atPath: existingPath) {
                } else {
                    db.updateFilePath(forHash: h, newPath: fp)
                    return .movedOrRenamed
                }
            }
            if let staleId = db.softDeletedComicId(atPath: fp) {
                ThumbnailCache.shared.evict(staleId)
            }
            let root = matchingRoot(for: fp, in: libraryRoots) ?? libraryRoots.first ?? ""
            let meta = parseMeta(url: url, libraryPath: root)
            // Uses batchInsert so all parsed ComicInfo.xml fields are stored.
            db.batchInsert([DatabaseManager.ComicInsert(
                title: meta.title, filePath: fp, publisher: meta.publisher,
                character: meta.character, series: meta.series,
                issueNumber: meta.issueNumber, pageCount: pageCount(fp),
                writer: meta.writer, penciller: meta.penciller,
                year: meta.year, storyArc: meta.storyArc,
                languageIso: meta.languageIso, fileHash: hash,
                coverMonth: meta.coverMonth, coverDay: meta.coverDay,
                alternateNumber: meta.alternateNumber, storyArcNumber: meta.storyArcNumber,
                seriesGroup: meta.seriesGroup, comicInfoIssueNumber: meta.comicInfoIssueNumber,
                volume: meta.volume, format: meta.format, hasComicInfo: meta.hasComicInfo,
                comicInfoSeries: meta.comicInfoSeries, comicInfoPublisher: meta.comicInfoPublisher,
                folderSeries: meta.folderSeries, folderPublisher: meta.folderPublisher, folderGroup: meta.folderGroup,
                seriesSource: meta.seriesSource, publisherSource: meta.publisherSource,
                issueNumberSource: meta.issueNumberSource
            )])
            return .added
        }
    }

    /// Returns the soft-deleted ids so the caller can remove their Spotlight entries.
    @discardableResult
    func removeSingle(path: String) -> [Int64] {
        queue.sync {
            let stale = db.stalePaths().filter { $0.path == path }.map(\.id)
            if !stale.isEmpty {
                db.softDelete(stale, reason: "missing")
                stale.forEach { ThumbnailCache.shared.evict($0) }
            }
            return stale
        }
    }

    func fileHash(_ path: String) -> String? {
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
    let imageExts = LibraryScanner.imageExtensions

    #if os(macOS)
    private func cbrPageCount(_ path: String) -> Int {
        guard ExternalTool.shared.which("unar") != nil else { return 0 }
        return cbrImageListing(path).count
    }

    private let cbrListingLock = NSLock()
    private var cbrListingCache: [String: [String]] = [:]
    /// Insertion order for `cbrListingCache`, so eviction drops the oldest entries.
    private var cbrListingOrder: [String] = []

    private static let maxCBRSizeBytes: UInt64 = 5 * 1024 * 1024 * 1024

    private func cbrImageListing(_ path: String) -> [String] {
        cbrListingLock.lock()
        if let cached = cbrListingCache[path] { cbrListingLock.unlock(); return cached }
        cbrListingLock.unlock()
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        guard UInt64(size) <= Self.maxCBRSizeBytes else { return [] }
        guard let lsar = ExternalTool.shared.which("lsar") else { return [] }
        let listing = ExternalTool.shared.shell(lsar, args: [path])
        let images = listing.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { imageExts.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        cbrListingLock.lock()
        cbrListingCache[path] = images
        cbrListingOrder.append(path)
        while cbrListingOrder.count > 500 {
            cbrListingCache.removeValue(forKey: cbrListingOrder.removeFirst())
        }
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
        var comicInfoSeries: String?
        var comicInfoPublisher: String?
        var folderSeries: String?
        var folderPublisher: String?
        var folderGroup: String?
        var seriesSource: String
        var publisherSource: String
        var issueNumberSource: String
    }

    /// One-time pass over comics that predate the raw-fact columns: records what each ComicInfo.xml
    /// says and flags real disagreements.
    func runImportPriorityAudit() {
        guard !db.hasCompletedImportPriorityAudit() else { return }
        let pending = db.pendingImportPriorityAuditPaths()
        guard !pending.isEmpty else {
            db.markImportPriorityAuditComplete()
            return
        }

        let currentValues = db.identitySnapshots(for: pending.map(\.id))
        var mirrorUpdates: [(id: Int64, comicInfoSeries: String?, comicInfoPublisher: String?)] = []
        var conflicts: [DatabaseManager.MetadataConflictInput] = []

        for (id, path) in pending {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let ci = comicInfoXML(url: URL(fileURLWithPath: path))
            let comicInfoSeries = ci["Series"].map(normalizeSeriesName)
            let comicInfoPublisher = ci["Publisher"].map(normalizePublisher)
            mirrorUpdates.append((id, comicInfoSeries, comicInfoPublisher))

            guard let current = currentValues[id], !current.metaEdited else { continue }
            if let conflict = DatabaseManager.detectMetadataConflict(
                field: "series", current: current.series, proposed: comicInfoSeries,
                source: "ComicInfo.xml", comicId: id
            ) {
                conflicts.append(conflict)
            }
            if let conflict = DatabaseManager.detectMetadataConflict(
                field: "publisher", current: current.publisher, proposed: comicInfoPublisher,
                source: "ComicInfo.xml", comicId: id
            ) {
                conflicts.append(conflict)
            }
        }

        db.updateComicInfoMirrors(mirrorUpdates)
        if !conflicts.isEmpty { db.upsertMetadataConflicts(conflicts) }
        db.markImportPriorityAuditComplete()
    }

    private func parseMeta(url: URL, libraryPath: String) -> ComicMeta {
        let ci = comicInfoXML(url: url)
        let filename = url.deletingPathExtension().lastPathComponent
        let (folderPublisher, folderCharacter, folderGroup, folderSeries) = folderComponents(url: url, libraryPath: libraryPath)
        let comicInfoSeries = ci["Series"].map(normalizeSeriesName)
        let comicInfoPublisher = ci["Publisher"].map(normalizePublisher)

        let resolved = ComicIdentityResolver.resolve(.init(
            comicInfoSeries: comicInfoSeries, comicInfoPublisher: comicInfoPublisher,
            comicInfoIssueNumber: ci["IssueNumber"],
            folderSeries: folderSeries, folderPublisher: folderPublisher,
            filenameIssueNumber: extractIssueNumber(from: filename)
        ))

        let character: String?
        if let fc = folderCharacter { character = fc }
        else if let c = ci["Characters"], isCleanCharacterName(c) { character = c }
        else { character = nil }

        let title = filename

        let year = ci["Year"].flatMap(Int.init) ?? extractYear(from: filename)
        let month = year != nil ? ci["Month"].flatMap(Int.init).flatMap { (1...12).contains($0) ? $0 : nil } : nil
        let day = month != nil ? ci["Day"].flatMap(Int.init).flatMap { (1...31).contains($0) ? $0 : nil } : nil
        return ComicMeta(title: title, publisher: resolved.publisher, character: character,
                         series: resolved.series, issueNumber: resolved.issueNumber,
                         writer: ci["Writer"], penciller: ci["Penciller"],
                         year: year, coverMonth: month, coverDay: day,
                         storyArc: ci["StoryArc"], languageIso: ci["LanguageISO"],
                         alternateNumber: ci["AlternateNumber"], storyArcNumber: ci["StoryArcNumber"],
                         seriesGroup: ci["SeriesGroup"].map(normalizeSeriesName),
                         comicInfoIssueNumber: ci["IssueNumber"],
                         volume: ci["Volume"], format: ci["Format"],
                         hasComicInfo: !ci.isEmpty,
                         comicInfoSeries: comicInfoSeries, comicInfoPublisher: comicInfoPublisher,
                         folderSeries: folderSeries, folderPublisher: folderPublisher, folderGroup: folderGroup,
                         seriesSource: resolved.seriesSource, publisherSource: resolved.publisherSource,
                         issueNumberSource: resolved.issueNumberSource)
    }

    /// `group` is the folder(s) between the Character and Series folders, e.g. "Batman (Modern)" in
    /// `DC/Batman/Batman (Modern)/Batman (2016)/`.
    func folderComponents(url: URL, libraryPath: String) -> (publisher: String?, character: String?, group: String?, series: String?) {
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
        case 0: return (nil, nil, nil, nil)
        case 1: return (nil, nil, nil, folders[0])
        case 2: return (normalizePublisher(folders[0]), nil, nil, folders[1])
        case 3:
            return (normalizePublisher(folders[0]), folders[1], nil, folders[2])
        default:
            let group = folders[2..<(folders.count - 1)].joined(separator: " / ")
            return (normalizePublisher(folders[0]), folders[1], group, folders[folders.count - 1])
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

    func reparseAllMeta(libraryRoots: [String]) {
        let comics = DatabaseManager.shared.allComicPaths()
        var updates: [(id: Int64, pub: String?, char: String?, ser: String?, title: String, issueNumber: String?, year: Int?, group: String?)] = []
        for (id, path) in comics {
            let url = URL(fileURLWithPath: path)
            let root = matchingRoot(for: path, in: libraryRoots) ?? ""
            let (pub, char, group, ser) = folderComponents(url: url, libraryPath: root)
            let filename = url.deletingPathExtension().lastPathComponent
            updates.append((id, pub, char, ser, filename, extractIssueNumber(from: filename), extractYear(from: filename), group))
        }
        DatabaseManager.shared.batchUpdateFolderMeta(updates)
        DatabaseManager.shared.resetScanRetryCounts()
    }

    /// Caps decompression at 5 MB so a malformed entry can't exhaust memory.
    private static let maxComicInfoXMLSizeBytes: UInt64 = 5 * 1024 * 1024

    private func comicInfoXML(url: URL) -> [String: String] {
        guard url.pathExtension.lowercased() == "cbz",
              let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil),
              let entry = archive.first(where: { $0.path.lowercased().hasSuffix("comicinfo.xml") }),
              entry.uncompressedSize <= Self.maxComicInfoXMLSizeBytes else { return [:] }
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

    // Most specific first; the bare-number fallback must come last or a year like "2020" is read as
    // the issue number.
    private static let issuePatterns: [NSRegularExpression] = [
        "#(\\d+(?:\\.\\d+)?)", "(?:issue|iss|no\\.?)\\s*(\\d+)",
        "v\\d+\\s*#(\\d+)", "(?:^|\\s|_)(\\d{1,4})(?:\\s|_|$)"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    func extractIssueNumber(from filename: String) -> String? {
        for regex in Self.issuePatterns {
            if let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
               let range = Range(match.range(at: 1), in: filename) { return String(filename[range]) }
        }
        return nil
    }

    // A "(YYYY)" or "(YYYY-)" year in the filename, e.g. "Amazing_Spider-Man_(2014)_#10".
    private static let yearPattern = try? NSRegularExpression(pattern: #"\((19|20)(\d{2})-?\)"#)

    /// Year from the filename, for the many comics without ComicInfo.xml.
    func extractYear(from filename: String) -> Int? {
        guard let regex = Self.yearPattern,
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let centuryRange = Range(match.range(at: 1), in: filename),
              let yearRange = Range(match.range(at: 2), in: filename)
        else { return nil }
        return Int(filename[centuryRange] + filename[yearRange])
    }

    private func normalizePublisher(_ raw: String) -> String {
        let map = ["dc": "DC", "marvel": "Marvel", "image": "Image", "dark horse": "Dark Horse",
                   "idw": "IDW", "boom": "BOOM!", "dynamite": "Dynamite"]
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return map[lower] ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeSeriesName(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }

    #if os(macOS)
    func terminateActiveProcess() { ExternalTool.shared.terminateActiveProcess() }
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
