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
        let cbrEnabled = UserDefaults.standard.object(forKey: "cbrEnabled") == nil
            || UserDefaults.standard.bool(forKey: "cbrEnabled")
        return cbrEnabled ? ["cbz", "cbr", "pdf", "jpg", "jpeg", "png"] : ["cbz", "pdf", "jpg", "jpeg", "png"]
        #else
        ["cbz", "pdf", "jpg", "jpeg", "png"]
        #endif
    }
    private var supported: Set<String> { Self.supportedExtensions }

    /// What can be opened/dropped/imported directly as a comic file (Finder, Services menu, drag
    /// and drop) -- loose images only count when scanned as part of a folder.
    static let importableExtensions: Set<String> = ["cbz", "cbr", "pdf"]

    struct ScanState: Sendable {
        var running = false; var total = 0; var done = 0; var added = 0
        var removed = 0; var recovered = 0; var stillCorrupted = 0
        var cancelled = false; var error: String?
        /// Ids soft-deleted by this scan, so a caller can remove their stale Spotlight entries --
        /// indexSearchableItems is additive-only and would otherwise leave them permanently
        /// discoverable, the same gap already fixed for interactive delete in LibraryViewModel.
        var removedIds: [Int64] = []
        /// Anything added, removed, moved, or renamed -- lets callers skip whole-library
        /// follow-up work (Spotlight re-index, duplicate detection) after a no-op scan.
        var changed = false
    }

    private let stateLock = NSLock()
    private var _state = ScanState()
    /// Every caller's `onProgress` closure for the scan currently in flight -- not just the one
    /// that happened to win the atomic check-and-set below. Without this, a caller that loses the
    /// race (another scan already running) previously just `return`ed with its `onProgress` never
    /// invoked even once, so whatever flag it set right before calling `scan()` (e.g.
    /// `LibraryViewModel.isScanning`) never got reset -- permanently wedging that caller's "busy"
    /// state until the app relaunches, since only the winning caller's own closure was ever told
    /// the scan had finished. Cleared once the in-flight scan actually finishes.
    private var observers: [(ScanState) -> Void] = []

    var state: ScanState { stateLock.lock(); defer { stateLock.unlock() }; return _state }
    private func setState(_ block: (inout ScanState) -> Void) { stateLock.lock(); defer { stateLock.unlock() }; block(&_state) }
    func cancel() { setState { $0.cancelled = true } }

    /// Notifies every registered observer (the scan's original caller plus anyone who called
    /// `scan()` again while it was already running) with the current state, on the main thread --
    /// matching every previous direct `onProgress(...)` call site's dispatch. Once the state is no
    /// longer `running`, the observer list is cleared so it doesn't leak into the next scan.
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

    /// Longest-prefix match among the configured library roots for a real file path -- roots
    /// aren't expected to nest, but matching the longest one first is a cheap safety net if they
    /// somehow do. Returns `nil` if the path doesn't fall under any currently configured root
    /// (e.g. a folder was removed from the library after comics were already imported from it).
    func matchingRoot(for path: String, in roots: [String]) -> String? {
        roots.filter { root in
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path == root || path.hasPrefix(prefix)
        }.max { $0.count < $1.count }
    }

    func scan(libraryPaths: [String], onProgress: @escaping (ScanState) -> Void) {
        // Check-and-set must happen as one atomic step under `stateLock` -- reading `state.running`
        // here and only flipping it to true later, inside `_scan` once it actually starts on
        // `queue`, leaves a window where two near-simultaneous callers (e.g. an auto-scan trigger
        // and a manual Resync click) both see `running == false` and both get enqueued.
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
            // A soft-deleted comic at this exact path is about to be revived (see _insertRow's
            // ON CONFLICT). Its cached cover may have been generated from a bad read while the
            // file was flaky/inaccessible right before it got marked stale -- evict it now so the
            // revived comic gets a genuinely fresh extraction instead of a possibly-wrong cover.
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
            // A file's identity survives a move/rename via its hash, but the folder-derived
            // publisher/character/series/title/issue-number it was tagged with at its OLD path
            // don't automatically follow -- a renamed folder (every file inside inherits a new
            // path) would otherwise leave every comic in it permanently tagged with whatever
            // series name the old folder happened to have. Reuses
            // the same folder-metadata derivation `reparseAllMeta` uses for a full manual
            // resync, respecting meta_edited the same way, just scoped to only the files that
            // actually moved this scan instead of the whole library.
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
            // Only comics whose matching root is CURRENTLY reachable are even considered for
            // staleness -- a root that's temporarily unreachable (asleep NAS, ejected drive) must
            // not have its comics judged missing just because we can't check them right now, and
            // a comic whose root was removed from the configured folder list entirely is left
            // alone rather than silently deleted just because the folder itself was unconfigured.
            let checkable = active.filter { comic in
                guard let root = matchingRoot(for: comic.path, in: libraryPaths) else { return false }
                return reachableRoots.contains(root)
            }
            let stale = checkable.filter { !fm.fileExists(atPath: $0.path) }.map(\.id)
            // A flaky/waking external drive or network share can resolve the library ROOT path
            // fine while individual file-existence checks transiently false-negative -- if that
            // happens, this would otherwise read as "most of the library vanished overnight" and
            // soft-delete all of it. A single user genuinely deleting most of a small library is
            // plausible and shouldn't be blocked, so this only guards a large ABSOLUTE count too.
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
            // A hash match against a known comic could mean two things: a genuine duplicate file
            // (the original is still where it was), or this IS the original, just renamed/moved
            // by Finder -- the file watcher reports that as a new path with no matching "removed"
            // linkage. Mirrors _scan()'s disambiguation: a move/rename updates the existing row in
            // place, but a genuine duplicate (the original path still exists) falls through to the
            // normal insert below instead of being silently dropped -- this exact branch used to
            // just `return` here, meaning any drag-and-dropped or file-watcher-detected file that
            // happened to be byte-identical to an already-known comic (a reprint, a duplicate copy,
            // the same crossover issue filed under two series) was silently never added at all.
            if let h = hash, db.knownHashes().contains(h) {
                if let existingPath = db.path(forHash: h), fm.fileExists(atPath: existingPath) {
                    // Genuine duplicate -- fall through to the insert below so it's actually added
                    // (and becomes visible to Possible Duplicates, like a full rescan would do).
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
            // Use batchInsert (ComicInsert), not the narrow 13-field insert(comic:) tuple overload
            // -- that overload silently drops coverMonth/coverDay/alternateNumber/storyArcNumber/
            // seriesGroup/comicInfoIssueNumber/volume/format/hasComicInfo even though parseMeta
            // computes all of them, permanently losing ComicInfo.xml metadata for every
            // drag-and-drop import and every file-watcher-detected new file.
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

    /// Returns the ids soft-deleted, if any, so the caller can remove their Spotlight entries --
    /// see `ScanState.removedIds`.
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
    /// Insertion order for `cbrListingCache`, oldest first -- a plain Dictionary has no ordering
    /// of its own, so this is what lets eviction drop only the oldest entries instead of wiping
    /// the whole cache (and forcing every still-being-read comic to re-run `lsar`) every time the
    /// cap is hit.
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

    /// One-time, post-upgrade pass over comics that predate the raw-fact mirror columns: reopens
    /// each one's archive to see what its ComicInfo.xml actually says, records it as a raw fact
    /// (comicinfo_series/comicinfo_publisher) regardless of the outcome, and flags a review
    /// conflict if it genuinely disagrees with what the file's series/publisher already are (the
    /// same disagreement rule `batchInsert` uses going forward, via
    /// `DatabaseManager.detectMetadataConflict`). Scoped to `has_comicinfo = 1` rows only -- well
    /// under 1% of a real library per the same rarity this scanner already assumes elsewhere --
    /// so reopening archives here is bounded, not a full-library rescan. Self-gated so it only
    /// ever does real work once per install; piggybacks on the next scan instead of adding a
    /// separate blocking step to app launch.
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

    /// `group` is whatever folder(s) sit between the Character folder and the Series folder
    /// itself -- e.g. "Batman (Modern)" in `DC/Batman/Batman (Modern)/Batman (2016)/file.cbz`.
    /// Previously silently discarded (only the first, second, and last folder mattered), so a
    /// 4th level a user built to group volumes/eras existed on disk but was invisible everywhere
    /// in the app. Multiple in-between folders (5+ levels deep) are joined with " / ", though
    /// that's a rare, unusual layout -- nil for the much more common 1-3 level case.
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

    /// A real ComicInfo.xml is a few KB at most -- this caps decompression at 5MB, generous
    /// headroom over any legitimate file, so a crafted or corrupted entry that claims a tiny
    /// compressed size but a huge uncompressed one can't be used to exhaust memory during an
    /// ordinary scan (this runs on every CBZ found, unconditionally, no user action needed).
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

    // Ordered most-specific-first: the bare `(?:^|\s|_)(\d{1,4})(?:\s|_|$)` fallback is tried
    // LAST deliberately -- it used to run before the explicit "issue"/"no." pattern, so a
    // filename like "Batman 2020 Issue 5.cbz" matched the bare pattern against "2020" (the first
    // free-standing number in the string) and never reached the explicit "Issue 5" pattern at
    // all, extracting the year as the issue number.
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

    // Matches a "(YYYY)" or "(YYYY-)" (ongoing series) year annotation anywhere in the filename,
    // e.g. "The_Amazing_Spider-Man_(2014)_Issue_#10" or "The_Amazing_Spider-Man_(2015-)_#1-4".
    private static let yearPattern = try? NSRegularExpression(pattern: #"\((19|20)(\d{2})-?\)"#)

    /// Fallback for the overwhelming majority of real libraries that have no ComicInfo.xml at all
    /// (confirmed: <1% of comics in a real 1900+ issue library had it) -- without this, `year` is
    /// simply never populated for those files even though the year is often sitting right in the
    /// filename already.
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
    /// Thin forwarder kept for existing callers (`LibraryViewModel.shutdown()`) -- the actual
    /// process-launching lives in `ExternalTool`, shared with `CBRDocument`'s reading-time
    /// extraction, so there's exactly one place that tracks the currently-running subprocess.
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
