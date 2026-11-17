import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()
    let queue = DispatchQueue(label: "com.comicarc.mac.db", qos: .userInitiated)
    var db: OpaquePointer?
    /// This instance's database file; backups and covers live beside it.
    let dbURL: URL
    var backupURL: URL { URL(fileURLWithPath: dbURL.path + ".bak") }
    var coversDir: URL { dbURL.deletingLastPathComponent().appendingPathComponent("covers") }

    static let dataDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ComicArc")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    convenience init() {
        self.init(dbPath: Self.dataDir.appendingPathComponent("comics.db").path)
    }

    init(dbPath path: String) {
        dbURL = URL(fileURLWithPath: path)
        guard sqlite3_open(path, &db) == SQLITE_OK else { return }
        exec("PRAGMA foreign_keys = ON")
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("PRAGMA cache_size = -8000")
        exec("PRAGMA journal_size_limit = 67108864")
        exec("PRAGMA mmap_size = 268435456")
        registerCustomFunctions()
        recoverIfCorrupted(dbURL: dbURL)
        migrate()
        // Backup runs off-queue so a large checkpoint + copy can't block launch. Not on
        // `self.queue`: refreshBackup() calls queue.sync and would deadlock.
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.refreshBackup() }
    }

    func registerCustomFunctions() {
        let deterministicUTF8 = Int32(SQLITE_UTF8) | Int32(SQLITE_DETERMINISTIC)

        sqlite3_create_function_v2(db, "is_special_issue", 3, deterministicUTF8, nil, { context, argc, argv in
            guard let context, let argv, argc >= 3 else { return }
            func text(_ i: Int32) -> String {
                guard let p = sqlite3_value_text(argv[Int(i)]) else { return "" }
                return String(cString: p)
            }
            let special = ComicSortClassifier.isSpecialIssue(issueNumber: text(0), title: text(1))
            sqlite3_result_int(context, special ? 1 : 0)
        }, nil, nil, nil)

        sqlite3_create_function_v2(db, "comic_type", 4, deterministicUTF8, nil, { context, argc, argv in
            guard let context, let argv, argc >= 4 else { return }
            func text(_ i: Int32) -> String {
                guard let p = sqlite3_value_text(argv[Int(i)]) else { return "" }
                return String(cString: p)
            }
            let type = ComicTypeClassifier.classify(issueNumber: text(0), title: text(1), format: text(3))
            sqlite3_result_text(context, type.rawValue, -1, SQLITE_TRANSIENT)
        }, nil, nil, nil)
    }

    func recoverIfCorrupted(dbURL: URL) {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &raw, nil) == SQLITE_OK,
              let stmt = raw else { return }
        defer { sqlite3_finalize(stmt) }
        var ok = false
        if sqlite3_step(stmt) == SQLITE_ROW,
           let p = sqlite3_column_text(stmt, 0),
           String(cString: p) == "ok" { ok = true }
        guard !ok else { return }

        let bakURL = backupURL
        guard FileManager.default.fileExists(atPath: bakURL.path) else { return }
        sqlite3_close(db); db = nil
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.copyItem(at: bakURL, to: dbURL)
        _ = sqlite3_open(dbURL.path, &db)
        // PRAGMAs are per-connection, so they must be reapplied on the new connection.
        exec("PRAGMA foreign_keys = ON")
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("PRAGMA cache_size = -8000")
        exec("PRAGMA journal_size_limit = 67108864")
        exec("PRAGMA mmap_size = 268435456")
        registerCustomFunctions()
    }

    func checkpoint() {
        queue.sync {
            guard db != nil else { return }
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    func checkpointAndClose() {
        queue.sync {
            guard db != nil else { return }
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
            sqlite3_close(db)
            db = nil
        }
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func scalarInt(_ sql: String, args: [Any?] = []) -> Int {
        guard db != nil else { return 0 }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func scalarText(_ sql: String, args: [Any?] = []) -> String? {
        guard db != nil else { return nil }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL,
              let p = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: p)
    }

    func rows<T>(_ sql: String, args: [Any?] = [], map: (OpaquePointer) -> T) -> [T] {
        guard db != nil else { return [] }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { results.append(map(stmt)) }
        return results
    }

    func colText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: p)
    }
    func colInt(_ stmt: OpaquePointer, _ col: Int32) -> Int { Int(sqlite3_column_int(stmt, col)) }
    func colInt64(_ stmt: OpaquePointer, _ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }

    func colBool(_ stmt: OpaquePointer, _ col: Int32) -> Bool { sqlite3_column_int(stmt, col) != 0 }

    func bindArgs(_ stmt: OpaquePointer, args: [Any?]) {
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let s as String:  sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, SQLITE_TRANSIENT)
            case let n as Int64:   sqlite3_bind_int64(stmt, idx, n)
            case let n as Int:     sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Double:  sqlite3_bind_double(stmt, idx, n)
            case .none:            sqlite3_bind_null(stmt, idx)
            default:               sqlite3_bind_null(stmt, idx)
            }
        }
    }

    @discardableResult
    func run(_ sql: String, args: [Any?] = []) -> Int64 {
        guard db != nil else { return -1 }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return -1 }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    /// Runs `body` in a transaction, rolling back if it returns false.
    @discardableResult
    func inTransaction(_ body: () -> Bool) -> Bool {
        exec("BEGIN")
        guard body() else { exec("ROLLBACK"); return false }
        exec("COMMIT")
        return true
    }

    /// Executes one prepared statement for every row. Call inside `inTransaction`; returns false on
    /// the first failure.
    @discardableResult
    func runBatch(_ sql: String, rows: [[Any?]]) -> Bool {
        guard !rows.isEmpty else { return true }
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return false }
        defer { sqlite3_finalize(s) }
        for args in rows {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            bindArgs(s, args: args)
            guard sqlite3_step(s) == SQLITE_DONE else { return false }
        }
        return true
    }

    /// Splits ids for `IN (...)` clauses, keeping each chunk under SQLite's bound-parameter limit.
    func idChunks<T>(_ ids: [T], size: Int = 500) -> [[T]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<Swift.min($0 + size, ids.count)]) }
    }

    /// Refreshes `comics.db.bak`, the snapshot `recoverIfCorrupted` falls back to. Runs at launch
    /// and after each scan.
    func refreshBackup() {
        queue.sync {
            let dbPath = dbURL
            let bakPath = backupURL
            guard FileManager.default.fileExists(atPath: dbPath.path) else { return }
            // Checkpoint first so the backup includes writes still in the WAL file.
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
            try? FileManager.default.removeItem(at: bakPath)
            try? FileManager.default.copyItem(at: dbPath, to: bakPath)
        }
    }

    func comicRow(_ s: OpaquePointer) -> Comic { comicRow(s, offset: 0) }

    /// Reads a `Comic` whose `comicColumns` start at `offset` (e.g. after a join row's own
    /// columns).
    func comicRow(_ s: OpaquePointer, offset: Int32) -> Comic {
        Comic(
            id: colInt64(s, offset), title: colText(s, offset + 1) ?? "", filePath: colText(s, offset + 2) ?? "",
            publisher: colText(s, offset + 3) ?? "Unknown", character: colText(s, offset + 4),
            series: colText(s, offset + 5) ?? "General", issueNumber: colText(s, offset + 6),
            pageCount: colInt(s, offset + 7), writer: colText(s, offset + 8), penciller: colText(s, offset + 9),
            year: sqlite3_column_type(s, offset + 10) != SQLITE_NULL ? colInt(s, offset + 10) : nil,
            volume: colText(s, offset + 20), format: colText(s, offset + 21),
            storyArc: colText(s, offset + 11), languageIso: colText(s, offset + 12), notes: colText(s, offset + 13),
            addedAt: colText(s, offset + 14) ?? "",
            position: colInt(s, offset + 15), fileHash: colText(s, offset + 16),
            progress: colInt(s, offset + 17),
            isFavorite: colBool(s, offset + 18), inReadingList: colBool(s, offset + 19),
            deletedReason: colText(s, offset + 22),
            finishedAt: colText(s, offset + 23),
            folderGroup: colText(s, offset + 24)
        )
    }

    let comicColumns = """
        c.id, c.title, c.file_path, c.publisher, c.character, c.series,
        c.issue_number, c.page_count, c.writer, c.penciller, c.year,
        c.story_arc, c.language_iso, c.notes, c.added_at,
        COALESCE(c.position, c.id), c.file_hash,
        COALESCE(rp.current_page, 0) as progress,
        (f.comic_id IS NOT NULL) as is_favorite,
        (rl.comic_id IS NOT NULL) as in_reading_list,
        c.volume, c.format,
        c.deleted_reason, rp.finished_at, c.folder_group
    """

    /// Progress, favorite, and Reading List joins every comic query needs.
    var comicJoins: String {
        """
        LEFT JOIN reading_progress rp ON c.id = rp.comic_id
        LEFT JOIN favorites f         ON c.id = f.comic_id
        LEFT JOIN run_items rl        ON rl.comic_id = c.id AND rl.run_id = \(Self.readingListRunIdSQL)
        """
    }

    var comicSelect: String {
        """
        SELECT \(comicColumns)
        FROM comics c
        \(comicJoins)
        """
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case publisher = "Publisher", title = "Title", dateAdded = "Recently Added",
             progress = "Most Read", manual = "Custom",
             year = "Year", storyArc = "Story Arc", pageCount = "Page Count",
             dateRead = "Recently Read", writer = "Writer"
        var id: String { rawValue }

        var clause: String {
            switch self {
            case .publisher: return "c.publisher, c.series, COALESCE(c.position, is_special_issue(c.issue_number, c.title, c.series) * \(ComicSortClassifier.specialBandOffset) + c.id), c.title"
            case .title:     return "c.title"
            case .dateAdded: return "c.added_at DESC"
            case .progress:  return "COALESCE(rp.current_page, 0) DESC, c.title"
            case .manual:    return "COALESCE(c.position, c.id), c.title"
            case .year:      return "COALESCE(c.year, 0) DESC, c.title"
            case .storyArc:  return "COALESCE(c.story_arc, ''), c.title"
            case .pageCount: return "c.page_count DESC, c.title"
            case .dateRead:  return "COALESCE(rp.last_read, '') DESC, c.title"
            case .writer:    return "COALESCE(c.writer, ''), c.title"
            }
        }
    }

    struct ComicInsert {
        let title: String, filePath: String
        var publisher: String
        let character: String?
        var series: String
        var issueNumber: String?
        let pageCount: Int, writer: String?
        let penciller: String?, year: Int?, storyArc: String?, languageIso: String?, fileHash: String?
        var coverMonth: Int? = nil
        var coverDay: Int? = nil
        var alternateNumber: String? = nil
        var storyArcNumber: String? = nil
        var seriesGroup: String? = nil
        var comicInfoIssueNumber: String? = nil
        var volume: String? = nil
        var format: String? = nil
        var hasComicInfo: Bool? = nil
        /// What ComicInfo.xml and the folder each said, independent of which one won.
        var comicInfoSeries: String? = nil
        var comicInfoPublisher: String? = nil
        var folderSeries: String? = nil
        var folderPublisher: String? = nil
        var folderGroup: String? = nil
        /// Which source won for series/publisher/issue number.
        var seriesSource: String = ComicIdentityResolver.defaultSource
        var publisherSource: String = ComicIdentityResolver.defaultSource
        var issueNumberSource: String = ComicIdentityResolver.defaultSource
    }

    /// Placeholder values the scanner writes when a source has nothing real.
    static let identityPlaceholders: Set<String> = ["general", "unknown"]
}
