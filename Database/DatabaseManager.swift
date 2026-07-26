import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()
    private let queue = DispatchQueue(label: "com.comicarc.mac.db", qos: .userInitiated)
    private var db: OpaquePointer?

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
        let dbURL = URL(fileURLWithPath: path)
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
    }

    private func registerCustomFunctions() {
        let deterministicUTF8 = Int32(SQLITE_UTF8) | Int32(SQLITE_DETERMINISTIC)

        sqlite3_create_function_v2(db, "is_special_issue", 3, deterministicUTF8, nil, { context, argc, argv in
            guard let context, let argv, argc >= 3 else { return }
            func text(_ i: Int32) -> String {
                guard let p = sqlite3_value_text(argv[Int(i)]) else { return "" }
                return String(cString: p)
            }
            let special = ComicSortClassifier.isSpecialIssue(issueNumber: text(0), title: text(1), series: text(2))
            sqlite3_result_int(context, special ? 1 : 0)
        }, nil, nil, nil)

        sqlite3_create_function_v2(db, "comic_type", 4, deterministicUTF8, nil, { context, argc, argv in
            guard let context, let argv, argc >= 4 else { return }
            func text(_ i: Int32) -> String {
                guard let p = sqlite3_value_text(argv[Int(i)]) else { return "" }
                return String(cString: p)
            }
            let type = ReadingOrderEngine.classify(issueNumber: text(0), title: text(1), series: text(2), format: text(3))
            sqlite3_result_text(context, type.rawValue, -1, SQLITE_TRANSIENT)
        }, nil, nil, nil)
    }

    private func recoverIfCorrupted(dbURL: URL) {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &raw, nil) == SQLITE_OK,
              let stmt = raw else { return }
        defer { sqlite3_finalize(stmt) }
        var ok = false
        if sqlite3_step(stmt) == SQLITE_ROW,
           let p = sqlite3_column_text(stmt, 0),
           String(cString: p) == "ok" { ok = true }
        guard !ok else { return }

        let bakURL = Self.dataDir.appendingPathComponent("comics.db.bak")
        guard FileManager.default.fileExists(atPath: bakURL.path) else { return }
        sqlite3_close(db); db = nil
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.copyItem(at: bakURL, to: dbURL)
        _ = sqlite3_open(dbURL.path, &db)
        // PRAGMAs are per-connection, not persisted in the file -- this is a brand new
        // connection, so foreign_keys/journal_mode/etc. default back off/unset unless
        // reapplied here. Without this, every ON DELETE CASCADE in the schema silently
        // stops firing for the rest of the app session after a corruption recovery.
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

    private func scalarInt(_ sql: String, args: [Any?] = []) -> Int {
        guard db != nil else { return 0 }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func scalarText(_ sql: String, args: [Any?] = []) -> String? {
        guard db != nil else { return nil }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL,
              let p = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: p)
    }

    private func rows<T>(_ sql: String, args: [Any?] = [], map: (OpaquePointer) -> T) -> [T] {
        guard db != nil else { return [] }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { results.append(map(stmt)) }
        return results
    }

    private func colText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: p)
    }
    private func colInt(_ stmt: OpaquePointer, _ col: Int32) -> Int { Int(sqlite3_column_int(stmt, col)) }
    private func colInt64(_ stmt: OpaquePointer, _ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }

    /// A caller (LibraryScanner, most commonly) can compute an affected group key before a
    /// backfill (Volume from a GCD match, series_group edit, etc.) has run -- if the row had no
    /// value yet, that key is a bare "publisher:series" with no volume/series_group component.
    /// Once the backfill lands, the row's real composite groupKey gains a suffix the caller's
    /// bare key never had, silently dropping it from a scoped WHERE ... IN filter. Expand every
    /// bare key to every real composite groupKey currently sharing that publisher/series so
    /// scoped recomputes (`recomputeReadingOrder`, `recomputeGCDMatches`) never miss a row purely
    /// because the caller's key predates a backfill.
    private func expandBareGroupKeys(_ keys: Set<String>) -> Set<String> {
        let bareKeys = keys.filter { $0.split(separator: ":", omittingEmptySubsequences: false).count <= 2 }
        guard !bareKeys.isEmpty else { return keys }
        let placeholders = bareKeys.map { _ in "?" }.joined(separator: ",")
        let resolvedKeys: [String] = rows("""
            SELECT DISTINCT publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), ''))
            FROM comics WHERE deleted_at IS NULL AND (publisher || ':' || series) IN (\(placeholders))
            """, args: bareKeys.map { $0 as Any? }) { s in colText(s, 0) ?? "" }
        return keys.union(resolvedKeys)
    }
    private func colBool(_ stmt: OpaquePointer, _ col: Int32) -> Bool { sqlite3_column_int(stmt, col) != 0 }

    private func bindArgs(_ stmt: OpaquePointer, args: [Any?]) {
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
    private func run(_ sql: String, args: [Any?] = []) -> Int64 {
        guard db != nil else { return -1 }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return -1 }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args: args)
        // Must actually check the result: silently ignoring a failed step (constraint violation,
        // SQLITE_BUSY, etc.) would fall through to sqlite3_last_insert_rowid, which on failure
        // still returns the *previous* successful insert's rowid -- handing callers a wrong id
        // that looks valid instead of a way to detect the write never happened.
        guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    /// Runs `body` inside a transaction, rolling back if it returns `false` (e.g. a `run(...)`
    /// call inside it returned -1). Used for batch mutations where a partial failure mid-loop
    /// would otherwise commit inconsistent data with no way to detect it after the fact.
    @discardableResult
    private func inTransaction(_ body: () -> Bool) -> Bool {
        exec("BEGIN")
        guard body() else { exec("ROLLBACK"); return false }
        exec("COMMIT")
        return true
    }

    /// Prepares `sql` once and reuses that single compiled statement across every row in
    /// `rows` (reset + re-bound each iteration) instead of calling `run(...)` per row, which
    /// re-parses and re-plans identical SQL text on every iteration. Meant to be called inside
    /// `inTransaction`; returns `false` on the first row that fails to step to completion.
    @discardableResult
    private func runBatch(_ sql: String, rows: [[Any?]]) -> Bool {
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

    private func migrate() {

        let dbPath = Self.dataDir.appendingPathComponent("comics.db")
        let bakPath = Self.dataDir.appendingPathComponent("comics.db.bak")
        if FileManager.default.fileExists(atPath: dbPath.path) {
            // Checkpoint first so the backup reflects all committed data, not just whatever has
            // landed in the main file so far -- WAL-mode commits can live only in the -wal file
            // for a while, and a prior session that ended without a full checkpoint (killed, not
            // quit normally) would otherwise be missing its most recent writes from this backup.
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
            // copyItem throws if the destination already exists, and the throw was silently
            // swallowed by `try?` below -- meaning this backup was actually only ever written
            // once, on the very first launch ever (likely a near-empty library), and silently
            // never updated on any later launch. A corruption recovery months later would have
            // rolled the whole library back to day one. Remove the stale backup first so this
            // snapshot is refreshed on every launch instead.
            try? FileManager.default.removeItem(at: bakPath)
            try? FileManager.default.copyItem(at: dbPath, to: bakPath)
        }
        exec("""
        CREATE TABLE IF NOT EXISTS comics (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            title        TEXT NOT NULL,
            file_path    TEXT UNIQUE NOT NULL,
            publisher    TEXT,
            character    TEXT,
            series       TEXT,
            issue_number TEXT,
            page_count   INTEGER DEFAULT 0,
            added_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            position     INTEGER,
            writer       TEXT,
            penciller    TEXT,
            year         INTEGER,
            story_arc    TEXT,
            language_iso TEXT,
            deleted_at   TIMESTAMP,
            notes        TEXT,
            file_hash    TEXT
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS reading_progress (
            comic_id     INTEGER PRIMARY KEY REFERENCES comics(id),
            current_page INTEGER DEFAULT 0,
            last_read    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS ratings (
            comic_id INTEGER PRIMARY KEY REFERENCES comics(id),
            rating   INTEGER CHECK(rating BETWEEN 1 AND 5),
            review   TEXT
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS favorites (
            comic_id INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS reading_list (
            comic_id INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE,
            added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS tags (
            id   INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS comic_tags (
            comic_id INTEGER REFERENCES comics(id) ON DELETE CASCADE,
            tag_id   INTEGER REFERENCES tags(id)   ON DELETE CASCADE,
            PRIMARY KEY (comic_id, tag_id)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS runs (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            title       TEXT NOT NULL,
            description TEXT,
            rating      INTEGER,
            review      TEXT,
            buy_link    TEXT,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS run_items (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id   INTEGER REFERENCES runs(id)   ON DELETE CASCADE,
            comic_id INTEGER REFERENCES comics(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            notes    TEXT DEFAULT '',
            UNIQUE(run_id, comic_id)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS lists (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            title       TEXT NOT NULL,
            description TEXT,
            rating      INTEGER,
            review      TEXT,
            position    INTEGER,
            cover_image_path TEXT,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS list_items (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            list_id  INTEGER REFERENCES lists(id)  ON DELETE CASCADE,
            comic_id INTEGER REFERENCES comics(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            notes    TEXT DEFAULT '',
            UNIQUE(list_id, comic_id)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS tier_lists (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            title       TEXT NOT NULL,
            description TEXT,
            position    INTEGER,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS tier_list_items (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            tier_list_id INTEGER REFERENCES tier_lists(id) ON DELETE CASCADE,
            comic_id     INTEGER REFERENCES comics(id)     ON DELETE CASCADE,
            tier         TEXT NOT NULL DEFAULT 'B',
            position     INTEGER NOT NULL,
            UNIQUE(tier_list_id, comic_id)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS bookmarks (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            comic_id   INTEGER REFERENCES comics(id) ON DELETE CASCADE,
            page       INTEGER NOT NULL,
            label      TEXT DEFAULT '',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(comic_id, page)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS reading_history (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            comic_id   INTEGER REFERENCES comics(id) ON DELETE CASCADE,
            page_start INTEGER NOT NULL DEFAULT 0,
            page_end   INTEGER NOT NULL DEFAULT 0,
            read_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS diary_entries (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            comic_id   INTEGER REFERENCES comics(id) ON DELETE CASCADE,
            rating     INTEGER CHECK(rating BETWEEN 1 AND 5),
            review     TEXT,
            is_reread  INTEGER NOT NULL DEFAULT 0,
            logged_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS reading_goals (
            year       INTEGER PRIMARY KEY,
            goal_count INTEGER NOT NULL DEFAULT 52
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_comics_publisher     ON comics(publisher)")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_series        ON comics(series)")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_pub_series    ON comics(publisher, series) WHERE deleted_at IS NULL")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_deleted       ON comics(deleted_at) WHERE deleted_at IS NULL")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_file_hash     ON comics(file_hash)")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_position      ON comics(position) WHERE deleted_at IS NULL")
        exec("CREATE INDEX IF NOT EXISTS idx_rp_last_read         ON reading_progress(last_read DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_rp_comic_id          ON reading_progress(comic_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_character     ON comics(character) WHERE deleted_at IS NULL")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_writer        ON comics(writer) WHERE deleted_at IS NULL")
        exec("CREATE INDEX IF NOT EXISTS idx_comics_year          ON comics(year) WHERE deleted_at IS NULL")
        exec("CREATE INDEX IF NOT EXISTS idx_comic_tags_comic_id  ON comic_tags(comic_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_comic_tags_tag_id    ON comic_tags(tag_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_run_items_run_id     ON run_items(run_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_run_items_comic_id   ON run_items(comic_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_list_items_list_id   ON list_items(list_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_list_items_comic_id  ON list_items(comic_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_tier_list_items_tier_list_id ON tier_list_items(tier_list_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_tier_list_items_comic_id     ON tier_list_items(comic_id)")
        exec("""
        CREATE TABLE IF NOT EXISTS series_covers (
            series    TEXT NOT NULL,
            publisher TEXT NOT NULL,
            comic_id  INTEGER REFERENCES comics(id) ON DELETE SET NULL,
            PRIMARY KEY (series, publisher)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS series_reader_prefs (
            series        TEXT NOT NULL,
            publisher     TEXT NOT NULL,
            fit_mode      TEXT NOT NULL,
            rtl           INTEGER NOT NULL,
            double_spread INTEGER NOT NULL,
            scroll_mode   INTEGER NOT NULL,
            PRIMARY KEY (series, publisher)
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_history_read_at    ON reading_history(read_at DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_diary_comic_id     ON diary_entries(comic_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_diary_logged_at    ON diary_entries(logged_at DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_bookmarks_comic    ON bookmarks(comic_id)")
        exec("""
        CREATE TABLE IF NOT EXISTS character_covers (
            group_name TEXT NOT NULL,
            publisher  TEXT NOT NULL,
            image_path TEXT NOT NULL,
            PRIMARY KEY (group_name, publisher)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS series_order (
            group_name TEXT NOT NULL,
            publisher  TEXT NOT NULL,
            series     TEXT NOT NULL,
            position   INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (group_name, publisher, series)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS character_order (
            group_name TEXT NOT NULL,
            publisher  TEXT NOT NULL,
            position   INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (group_name, publisher)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS publisher_order (
            publisher TEXT PRIMARY KEY,
            position  INTEGER NOT NULL DEFAULT 0
        )
        """)


        exec("ALTER TABLE comics ADD COLUMN file_hash TEXT")
        exec("ALTER TABLE runs   ADD COLUMN rating INTEGER")
        exec("ALTER TABLE runs   ADD COLUMN review TEXT")
        exec("ALTER TABLE runs   ADD COLUMN buy_link TEXT")
        exec("ALTER TABLE comics ADD COLUMN notes TEXT")
        exec("ALTER TABLE comics ADD COLUMN character TEXT")
        exec("ALTER TABLE comics ADD COLUMN position INTEGER")
        exec("ALTER TABLE comics ADD COLUMN writer TEXT")
        exec("ALTER TABLE comics ADD COLUMN penciller TEXT")
        exec("ALTER TABLE comics ADD COLUMN year INTEGER")
        exec("ALTER TABLE comics ADD COLUMN story_arc TEXT")
        exec("ALTER TABLE comics ADD COLUMN language_iso TEXT")
        exec("ALTER TABLE comics ADD COLUMN deleted_at TIMESTAMP")
        exec("ALTER TABLE comics ADD COLUMN meta_edited INTEGER NOT NULL DEFAULT 0")
        exec("ALTER TABLE comics ADD COLUMN cover_month INTEGER")
        exec("ALTER TABLE runs   ADD COLUMN position INTEGER")
        exec("ALTER TABLE series_covers ADD COLUMN image_path TEXT")
        exec("ALTER TABLE runs   ADD COLUMN cover_image_path TEXT")

        exec("ALTER TABLE comics ADD COLUMN reading_order_position INTEGER")
        exec("ALTER TABLE comics ADD COLUMN reading_order_confidence INTEGER")
        exec("ALTER TABLE comics ADD COLUMN reading_order_reason TEXT")
        exec("ALTER TABLE comics ADD COLUMN alternate_number TEXT")
        exec("ALTER TABLE comics ADD COLUMN story_arc_number TEXT")
        exec("ALTER TABLE comics ADD COLUMN cover_day INTEGER")
        exec("ALTER TABLE comics ADD COLUMN series_group TEXT")
        exec("""
        CREATE TABLE IF NOT EXISTS reading_order_overrides (
            comic_id   INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE,
            position   INTEGER NOT NULL,
            reason     TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)

        exec("ALTER TABLE comics ADD COLUMN comicinfo_issue_number TEXT")

        exec("""
        CREATE TABLE IF NOT EXISTS series_links (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            parent_publisher TEXT NOT NULL,
            parent_series    TEXT NOT NULL,
            child_publisher  TEXT NOT NULL,
            child_series     TEXT NOT NULL,
            sequence_order   INTEGER NOT NULL,
            created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            source           TEXT NOT NULL DEFAULT 'manual',
            UNIQUE(child_publisher, child_series)
        )
        """)
        exec("ALTER TABLE series_links ADD COLUMN source TEXT NOT NULL DEFAULT 'manual'")
        makeSeriesLinksVolumeAwareIfNeeded()

        exec("ALTER TABLE comics ADD COLUMN gcd_issue_id INTEGER")
        exec("ALTER TABLE comics ADD COLUMN gcd_cover_date TEXT")
        exec("ALTER TABLE comics ADD COLUMN gcd_match_confidence INTEGER")
        exec("ALTER TABLE comics ADD COLUMN gcd_match_reason TEXT")
        exec("ALTER TABLE comics ADD COLUMN gcd_series_name TEXT")
        exec("ALTER TABLE comics ADD COLUMN gcd_issue_number TEXT")
        // 'auto' (the default) means recomputeGCDMatches owns this row and may freely rewrite or
        // clear it on every rescan; 'manual' means a user explicitly picked this match via the
        // Fix Match picker, and recomputeGCDMatches must never overwrite it -- the same "don't
        // clobber a deliberate choice" pattern meta_edited already gives comics' identity fields.
        exec("ALTER TABLE comics ADD COLUMN gcd_match_source TEXT NOT NULL DEFAULT 'auto'")
        // Partial index, same pattern as idx_bookmarks_favorite/idx_metadata_conflicts_status --
        // 'manual' is a small fraction of a potentially 100k-row table, exactly the low-selectivity
        // shape a partial index helps most, and manualGCDMatchDetails() (backup export) scans it.
        exec("CREATE INDEX IF NOT EXISTS idx_comics_gcd_manual ON comics(gcd_match_source) WHERE gcd_match_source = 'manual'")

        exec("ALTER TABLE comics ADD COLUMN volume TEXT")

        exec("ALTER TABLE comics ADD COLUMN format TEXT")

        exec("ALTER TABLE comics ADD COLUMN has_comicinfo INTEGER")

        exec("ALTER TABLE comics ADD COLUMN scan_retry_count INTEGER NOT NULL DEFAULT 0")
        exec("ALTER TABLE tags ADD COLUMN category TEXT")

        exec("CREATE INDEX IF NOT EXISTS idx_comics_pub_series_issue ON comics(publisher, series, issue_number) WHERE deleted_at IS NULL")

        // Raw-fact mirrors: comicinfo_issue_number (above) already preserves what ComicInfo.xml
        // said even when a different source wins for the primary `issue_number` column -- these
        // extend that same pattern to series/publisher, plus the folder-derived guess, so a
        // priority decision made at import time can always be revisited later instead of being
        // silently permanent. Always written through unconditionally on every insert, never
        // gated by which source won.
        exec("ALTER TABLE comics ADD COLUMN comicinfo_series TEXT")
        exec("ALTER TABLE comics ADD COLUMN comicinfo_publisher TEXT")
        exec("ALTER TABLE comics ADD COLUMN folder_series TEXT")
        exec("ALTER TABLE comics ADD COLUMN folder_publisher TEXT")

        // A "favorite moment" is just a bookmark the user has flagged as worth revisiting on its
        // own -- not a new table, since every favorite moment is already a page-position bookmark
        // (with its own label). Distinct from the resume-reading position, which lives on `comics`.
        exec("ALTER TABLE bookmarks ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0")
        exec("CREATE INDEX IF NOT EXISTS idx_bookmarks_favorite ON bookmarks(is_favorite) WHERE is_favorite = 1")

        // Surfaces a disagreement between an already-imported comic's current series/publisher/
        // issue_number and what a corrected priority resolution would now produce, instead of
        // silently overwriting (or silently ignoring) either side. UNIQUE(comic_id, field) so a
        // re-detected conflict updates the existing row (and re-opens it if it had been
        // dismissed) rather than accumulating duplicates.
        exec("""
        CREATE TABLE IF NOT EXISTS metadata_conflicts (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            comic_id        INTEGER NOT NULL REFERENCES comics(id) ON DELETE CASCADE,
            field           TEXT NOT NULL CHECK(field IN ('series','publisher','issue_number')),
            current_value   TEXT,
            proposed_value  TEXT,
            proposed_source TEXT NOT NULL,
            detected_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            status          TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','applied','dismissed')),
            resolved_at     TIMESTAMP,
            UNIQUE(comic_id, field)
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_metadata_conflicts_status ON metadata_conflicts(status) WHERE status = 'pending'")
        exec("CREATE INDEX IF NOT EXISTS idx_metadata_conflicts_comic  ON metadata_conflicts(comic_id)")

        exec("""
        UPDATE comics SET position =
            is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
            + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
        WHERE position IS NULL
        """)

        resortSpecialIssuesIfNeeded()
        widenMainlinePositionStrideIfNeeded()
        recomputeOnceAfterUpgradeIfNeeded()
    }

    private func recomputeOnceAfterUpgradeIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        let alreadyRun = scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'readingOrderRecomputeGateV1'") > 0
        guard !alreadyRun else { return }
        positionSpecialsChronologically()
        recomputeReadingOrder()
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('readingOrderRecomputeGateV1')")
    }

    private func resortSpecialIssuesIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        let alreadyRun = scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'specialIssueSortV1'") > 0
        guard !alreadyRun else { return }
        exec("""
        UPDATE comics SET position =
            is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
            + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
        """)
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('specialIssueSortV1')")
    }

    private func widenMainlinePositionStrideIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        let alreadyRun = scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'positionStride100V1'") > 0
        guard !alreadyRun else { return }
        exec("""
        UPDATE comics SET position =
            is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
            + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
        """)
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('positionStride100V1')")
    }

    // Adds parent_volume/child_volume so two series that share an identical Series name but
    // differ by ComicInfo.xml's Volume tag (the standard GCD/ComicVine convention for numbered
    // relaunches, e.g. Amazing Spider-Man Vol. 1 vs Vol. 2) can be linked as their own distinct
    // continuation instead of only ever resolving to one combined (publisher, series) candidate.
    // SQLite can't ALTER a UNIQUE constraint in place, so this rebuilds the table; the original
    // UNIQUE(child_publisher, child_series) is dropped in favor of the app-level uniqueness check
    // in addSeriesLink (NULL isn't equal to NULL for UNIQUE purposes, which would have let every
    // volume-less child bypass the constraint entirely).
    private func makeSeriesLinksVolumeAwareIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        let alreadyRun = scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'seriesLinksVolumeAwareV1'") > 0
        guard !alreadyRun else { return }
        exec("ALTER TABLE series_links RENAME TO series_links_old")
        exec("""
        CREATE TABLE series_links (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            parent_publisher TEXT NOT NULL,
            parent_series    TEXT NOT NULL,
            parent_volume    TEXT,
            child_publisher  TEXT NOT NULL,
            child_series     TEXT NOT NULL,
            child_volume     TEXT,
            sequence_order   INTEGER NOT NULL,
            created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            source           TEXT NOT NULL DEFAULT 'manual'
        )
        """)
        exec("""
        INSERT INTO series_links (id, parent_publisher, parent_series, parent_volume,
                                   child_publisher, child_series, child_volume,
                                   sequence_order, created_at, source)
        SELECT id, parent_publisher, parent_series, NULL, child_publisher, child_series, NULL,
               sequence_order, created_at, source FROM series_links_old
        """)
        exec("DROP TABLE series_links_old")
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('seriesLinksVolumeAwareV1')")
    }

    func seedMissingPositions() {
        queue.sync {
            _ = exec("""
            UPDATE comics SET position =
                is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
                + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
            WHERE position IS NULL
            """)
        }
    }

    func positionSpecialsChronologically(affectedGroupKeys: Set<String>? = nil) {
        queue.sync {
            struct Row { let id: Int64; let seriesKey: String; let special: Bool
                         let year: Int?; let month: Int?; let position: Int }
            var sql = """
            SELECT id, publisher || ':' || series,
                   is_special_issue(issue_number, title, series), year, cover_month,
                   COALESCE(position, id)
            FROM comics WHERE deleted_at IS NULL
            """
            var args: [Any?] = []
            if let keys = affectedGroupKeys {
                guard !keys.isEmpty else { return }
                let placeholders = keys.map { _ in "?" }.joined(separator: ",")
                sql += " AND (publisher || ':' || series) IN (\(placeholders))"
                args = Array(keys).map { $0 as Any? }
            }
            let allRows: [Row] = rows(sql, args: args) { s in
                Row(id: colInt64(s, 0), seriesKey: colText(s, 1) ?? "",
                    special: colInt(s, 2) != 0,
                    year:  sqlite3_column_type(s, 3) != SQLITE_NULL ? colInt(s, 3) : nil,
                    month: sqlite3_column_type(s, 4) != SQLITE_NULL ? colInt(s, 4) : nil,
                    position: colInt(s, 5))
            }

            var updates: [(Int64, Int)] = []
            for (_, group) in Dictionary(grouping: allRows, by: \.seriesKey) {
                let mainline = group.filter { !$0.special }.sorted { $0.position < $1.position }
                let mainlineDated = mainline.filter { $0.year != nil && $0.month != nil }
                let allSpecials = group.filter { $0.special }

                var placedIds = Set<Int64>()
                if mainlineDated.count >= 2 {
                    var byBracket: [Int: [(id: Int64, specialKey: Int)]] = [:]
                    for special in allSpecials {
                        guard let y = special.year, let m = special.month else { continue }
                        let specialKey = y * 100 + m
                        guard let afterIdx = mainlineDated.firstIndex(where: { $0.year! * 100 + $0.month! > specialKey }),
                              afterIdx > 0 else { continue }
                        byBracket[afterIdx - 1, default: []].append((special.id, specialKey))
                    }
                    for (beforeIdx, bracket) in byBracket {
                        let before = mainlineDated[beforeIdx]
                        let after  = mainlineDated[beforeIdx + 1]
                        guard after.position - before.position > 1 else { continue }
                        let sorted = bracket.sorted { $0.specialKey != $1.specialKey ? $0.specialKey < $1.specialKey : $0.id < $1.id }
                        let n = sorted.count
                        for (idx, item) in sorted.enumerated() {
                            let pos = n == 1
                                ? before.position + (after.position - before.position) / 2
                                : before.position + Int((Double(after.position - before.position) * (Double(idx + 1) / Double(n + 1))).rounded())
                            updates.append((item.id, pos))
                            placedIds.insert(item.id)
                        }
                    }
                }

                guard let minPos = mainline.first?.position, let maxPos = mainline.last?.position,
                      maxPos > minPos, mainline.count >= 2 else { continue }
                let undated = allSpecials
                    .filter { !placedIds.contains($0.id) && $0.position >= ComicSortClassifier.specialBandOffset }
                    .sorted { $0.position < $1.position }
                let n = undated.count
                guard n > 0 else { continue }
                for (idx, special) in undated.enumerated() {
                    let fraction = Double(idx + 1) / Double(n + 1)
                    let target = minPos + Int((Double(maxPos - minPos) * fraction).rounded())
                    updates.append((special.id, target))
                }
            }
            guard !updates.isEmpty else { return }
            inTransaction {
                runBatch("UPDATE comics SET position = ? WHERE id = ?",
                         rows: updates.map { [$0.1, $0.0] })
            }
        }
    }

    func recomputeReadingOrder(mode: ReadingOrderMode = .current, affectedGroupKeys: Set<String>? = nil) {
        queue.sync {
            struct Row {
                let id: Int64; let publisher: String; let series: String; let volume: String?; let groupKey: String
                let filePath: String; let issueNumber: String?; let comicInfoIssueNumber: String?
                let title: String
                let year: Int?; let month: Int?; let day: Int?; let storyArc: String?
                let gcdCoverDate: String?; let alternateNumber: String?; let format: String?
                let gcdIssueNumber: String?
            }

            let links: [(parentKey: String, childKey: String)] = rows("""
                SELECT parent_publisher, parent_series, COALESCE(NULLIF(parent_volume,''),''),
                       child_publisher, child_series, COALESCE(NULLIF(child_volume,''),'')
                FROM series_links ORDER BY sequence_order
                """
            ) { s in
                ("\(colText(s, 0) ?? ""):\(colText(s, 1) ?? ""):\(colText(s, 2) ?? "")",
                 "\(colText(s, 3) ?? ""):\(colText(s, 4) ?? ""):\(colText(s, 5) ?? "")")
            }
            let childSeriesKeys = Set(links.map(\.childKey))

            var effectiveKeys = affectedGroupKeys
            if effectiveKeys != nil, !links.isEmpty {
                // series_links stores raw "publisher:series:volume" keys, but the WHERE filter
                // below scopes rows by the composite groupKey (series_group/volume aware) that
                // LibraryScanner actually uses for affectedGroupKeys. A linked child whose
                // series_group differs from a plain "publisher:series:volume" (a normal pattern
                // for crossover tie-ins) would never match that raw key in the composite filter,
                // silently dropping its rows from allRows -- walk()'s parent offset would then
                // never reach it. Resolve each raw link key to every real composite groupKey
                // currently in use for it instead of unioning the raw key in directly.
                let linkedRawKeys = Set(links.map(\.parentKey) + links.map(\.childKey))
                if !linkedRawKeys.isEmpty {
                    let placeholders = linkedRawKeys.map { _ in "?" }.joined(separator: ",")
                    let resolvedKeys: [String] = rows("""
                        SELECT DISTINCT publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), ''))
                        FROM comics WHERE deleted_at IS NULL
                        AND (publisher || ':' || series || ':' || COALESCE(NULLIF(volume,''),'')) IN (\(placeholders))
                        """, args: linkedRawKeys.map { $0 as Any? }) { s in colText(s, 0) ?? "" }
                    effectiveKeys!.formUnion(resolvedKeys)
                }
            }

            if let keys = effectiveKeys, !keys.isEmpty {
                // A caller (LibraryScanner, most commonly) can compute an affected key before
                // recomputeGCDMatches has run -- if the comic had no ComicInfo.xml <Volume> tag
                // yet, that key is a bare "publisher:series" with no volume component at all. If
                // recomputeGCDMatches then backfills comics.volume from the matched GCD series'
                // own year, the row's real composite groupKey gains a volume suffix the caller's
                // key never had, silently dropping it from the filter below -- its
                // reading_order_position would never get set. Expand every such bare key to every
                // real composite groupKey currently sharing that publisher/series, the same way
                // series_links keys are resolved above.
                effectiveKeys = expandBareGroupKeys(keys)
            }

            var sql = """
            SELECT id, publisher, series, volume,
                   publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), '')),
                   file_path, issue_number, comicinfo_issue_number, title, year, cover_month, cover_day, story_arc,
                   gcd_cover_date, alternate_number, format, gcd_issue_number
            FROM comics WHERE deleted_at IS NULL
            """
            var args: [Any?] = []
            if let keys = effectiveKeys {
                guard !keys.isEmpty else { return }
                let placeholders = keys.map { _ in "?" }.joined(separator: ",")
                sql += " AND (publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), ''))) IN (\(placeholders))"
                args = Array(keys).map { $0 as Any? }
            }
            let allRows: [Row] = rows(sql, args: args) { s in
                Row(id: colInt64(s, 0), publisher: colText(s, 1) ?? "Unknown", series: colText(s, 2) ?? "General",
                    volume: colText(s, 3), groupKey: colText(s, 4) ?? "", filePath: colText(s, 5) ?? "",
                    issueNumber: colText(s, 6), comicInfoIssueNumber: colText(s, 7), title: colText(s, 8) ?? "",
                    year:  sqlite3_column_type(s, 9) != SQLITE_NULL ? colInt(s, 9) : nil,
                    month: sqlite3_column_type(s, 10) != SQLITE_NULL ? colInt(s, 10) : nil,
                    day:   sqlite3_column_type(s, 11) != SQLITE_NULL ? colInt(s, 11) : nil,
                    storyArc: colText(s, 12), gcdCoverDate: colText(s, 13), alternateNumber: colText(s, 14),
                    format: colText(s, 15), gcdIssueNumber: colText(s, 16))
            }

            var positions: [Int64: (position: Int, confidence: Int, reason: String)] = [:]

            switch mode {
            case .intelligent:
                var usedGCDDate: Set<Int64> = []
                let inputs = allRows.map { row -> ReadingOrderEngine.ReadingOrderInput in
                    var y = row.year, m = row.month, d = row.day
                    if let gcd = row.gcdCoverDate, let parsed = Self.parseGCDDate(gcd) {
                        y = parsed.year; m = parsed.month; d = parsed.day
                        usedGCDDate.insert(row.id)
                    }
                    let isChild = childSeriesKeys.contains(Self.seriesVolumeKey(publisher: row.publisher, series: row.series, volume: row.volume))
                    // alternate_number (an explicit ComicInfo.xml <AlternateNumber> tag) is the
                    // highest-trust signal when present, but it's set on well under 1% of real
                    // files. gcd_issue_number is recomputeGCDMatches' own verified legacy/
                    // continuity number for a matched volume restart -- without falling back to
                    // it here, a correctly-matched legacy renumbering (e.g. Amazing Spider-Man
                    // Vol. 2 continuing Vol. 1's numbering) would still sort by its bare
                    // volume-relative issue_number ("1") instead of its real place in the
                    // continuity, for every comic that doesn't also happen to carry the rare
                    // ComicInfo tag.
                    let legacyNumber = (isChild ? row.alternateNumber.flatMap(ReadingOrderEngine.parseLegacyNumber) : nil)
                        ?? (isChild ? row.gcdIssueNumber.flatMap(ReadingOrderEngine.parseLegacyNumber) : nil)
                        ?? ReadingOrderEngine.parseLegacyNumber(row.issueNumber)
                    return ReadingOrderEngine.ReadingOrderInput(
                        id: row.id, groupKey: row.groupKey,
                        legacyNumber: legacyNumber,
                        comicType: ReadingOrderEngine.classify(issueNumber: row.issueNumber, title: row.title, series: row.series, format: row.format),
                        year: y, month: m, day: d, storyArc: row.storyArc,
                        title: row.title
                    )
                }
                let results = ReadingOrderEngine.computeSeriesPositions(inputs)
                for row in allRows {
                    guard let r = results[row.id] else { continue }
                    if usedGCDDate.contains(row.id) {
                        positions[row.id] = (r.position, r.confidence, "Placed using its real publication date from the offline comics database")
                    } else {
                        positions[row.id] = (r.position, r.confidence, r.reason)
                    }
                }
            case .filename:
                break
            case .legacyNumber:
                for group in Dictionary(grouping: allRows, by: \.groupKey).values {
                    let ordered = group.sorted {
                        (ReadingOrderEngine.parseLegacyNumber($0.issueNumber) ?? .infinity, $0.title) <
                        (ReadingOrderEngine.parseLegacyNumber($1.issueNumber) ?? .infinity, $1.title)
                    }
                    for (idx, row) in ordered.enumerated() { positions[row.id] = (idx, 100, "Sorted by legacy issue number") }
                }
            case .publicationDate:
                for group in Dictionary(grouping: allRows, by: \.groupKey).values {
                    let ordered = group.sorted {
                        ($0.year ?? 9999, $0.month ?? 13, $0.day ?? 32, $0.title) <
                        ($1.year ?? 9999, $1.month ?? 13, $1.day ?? 32, $1.title)
                    }
                    for (idx, row) in ordered.enumerated() { positions[row.id] = (idx, 100, "Sorted by publication date") }
                }
            case .comicInfoOrder:
                func comicInfoOrderKey(_ row: Row) -> Double {
                    row.comicInfoIssueNumber.flatMap(ReadingOrderEngine.parseLegacyNumber)
                        ?? ReadingOrderEngine.parseLegacyNumber(row.issueNumber) ?? .infinity
                }
                for group in Dictionary(grouping: allRows, by: \.groupKey).values {
                    let ordered = group.sorted {
                        (comicInfoOrderKey($0), $0.title) < (comicInfoOrderKey($1), $1.title)
                    }
                    for (idx, row) in ordered.enumerated() {
                        let reason = row.comicInfoIssueNumber != nil
                            ? "Sorted by ComicInfo.xml issue number" : "Sorted by legacy issue number (no ComicInfo.xml number)"
                        positions[row.id] = (idx, 100, reason)
                    }
                }
            }

            if !links.isEmpty {
                var idsBySeriesKey: [String: [Int64]] = [:]
                for row in allRows {
                    idsBySeriesKey[Self.seriesVolumeKey(publisher: row.publisher, series: row.series, volume: row.volume), default: []].append(row.id)
                }
                let offsets = SeriesContinuity.chainOffsets(
                    links: links, idsBySeriesKey: idsBySeriesKey,
                    positions: positions.mapValues(\.position)
                )
                for (id, offset) in offsets {
                    positions[id]?.position += offset
                }
            }

            let overrideMap = Dictionary(uniqueKeysWithValues: rows(
                "SELECT comic_id, position FROM reading_order_overrides", map: { (colInt64($0, 0), colInt($0, 1)) }
            ))

            // Grouped by which UPDATE each row needs instead of interleaving one prepare/step
            // per row -- this runs over the whole affected set after every scan/reorder, so
            // reusing one compiled statement per branch instead of re-parsing identical SQL
            // text on every row matters at real-library scale.
            var overrideRows: [[Any?]] = []
            var filenameResetRows: [[Any?]] = []
            var positionRows: [[Any?]] = []
            for row in allRows {
                if let overridePos = overrideMap[row.id] {
                    overrideRows.append([overridePos, row.id])
                } else if mode == .filename {
                    filenameResetRows.append([row.id])
                } else if let p = positions[row.id] {
                    positionRows.append([p.position, p.confidence, p.reason, row.id])
                }
            }
            inTransaction {
                let ok1 = runBatch("""
                    UPDATE comics SET reading_order_position = ?, reading_order_confidence = 100,
                           reading_order_reason = 'Manually placed'
                    WHERE id = ?
                    """, rows: overrideRows)
                let ok2 = runBatch("""
                    UPDATE comics SET reading_order_position = NULL, reading_order_confidence = NULL,
                           reading_order_reason = NULL
                    WHERE id = ?
                    """, rows: filenameResetRows)
                let ok3 = runBatch("""
                    UPDATE comics SET reading_order_position = ?, reading_order_confidence = ?,
                           reading_order_reason = ?
                    WHERE id = ?
                    """, rows: positionRows)
                return ok1 && ok2 && ok3
            }
        }
    }

    /// Escapes literal `%`/`_`/`\` in free-text search input so a LIKE '%...%' pattern treats
    /// them as literal characters instead of wildcards (paired with `ESCAPE '\'` at each call site).
    private static func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func parseGCDDate(_ raw: String) -> (year: Int, month: Int?, day: Int?)? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), year > 0 else { return nil }
        let month = Int(parts[1]).flatMap { $0 > 0 ? $0 : nil }
        let day = month != nil ? Int(parts[2]).flatMap { $0 > 0 ? $0 : nil } : nil
        return (year, month, day)
    }

    func recomputeGCDMatches(affectedGroupKeys: Set<String>? = nil, store: OfflineMetadataStore = .shared) {
        guard store.isAvailable else { return }
        queue.sync {
            var effectiveKeys = affectedGroupKeys
            if let keys = effectiveKeys, !keys.isEmpty {
                // Mirrors recomputeReadingOrder's bare-key expansion: a caller (LibraryScanner,
                // most commonly, whether from a freshly-derived series or one just re-derived
                // after a folder rename) may not know a comic's current volume yet, so its key is
                // a bare "publisher:series". If a PRIOR pass already backfilled comics.volume for
                // that row (from a previous GCD match, or an edit), its real composite groupKey
                // now includes a volume suffix the bare key never had -- without this expansion
                // the row would be silently excluded and never get rematched.
                effectiveKeys = expandBareGroupKeys(keys)
            }

            var sql = """
                SELECT id, series, publisher, issue_number, year, title,
                       publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), '')),
                       format
                FROM comics WHERE deleted_at IS NULL AND gcd_match_source != 'manual'
            """
            var args: [Any?] = []
            if let keys = effectiveKeys {
                guard !keys.isEmpty else { return }
                let placeholders = keys.map { _ in "?" }.joined(separator: ",")
                sql += " AND (publisher || ':' || (COALESCE(NULLIF(series_group,''), series) || COALESCE(':' || NULLIF(volume,''), ''))) IN (\(placeholders))"
                args = Array(keys).map { $0 as Any? }
            }
            struct Row { let id: Int64; let series: String; let publisher: String; let issueNumber: String?; let year: Int?; let title: String; let format: String? }
            let candidates: [Row] = rows(sql, args: args) { s in
                Row(id: colInt64(s, 0), series: colText(s, 1) ?? "General", publisher: colText(s, 2) ?? "Unknown",
                    issueNumber: colText(s, 3), year: sqlite3_column_type(s, 4) != SQLITE_NULL ? colInt(s, 4) : nil,
                    title: colText(s, 5) ?? "", format: colText(s, 7))
            }
            var updateRows: [[Any?]] = []
            for row in candidates {
                let comicType = ReadingOrderEngine.classify(issueNumber: row.issueNumber, title: row.title, series: row.series, format: row.format)
                let match = store.lookupIssue(
                    series: row.series, publisher: row.publisher, issueNumber: row.issueNumber, year: row.year,
                    comicType: comicType
                )
                // Always write a row, even with every gcd_* field nil -- a comic that matched on a
                // previous pass (e.g. before an ambiguity fix like the ASM-Modern/1965 mismatch)
                // but no longer matches now must have that stale, possibly-wrong attribution
                // cleared, not silently left in place because this pass found nothing to replace
                // it with.
                updateRows.append([match?.gcdIssueId, match?.coverDate, match?.confidence, match?.reason,
                                   match?.canonicalSeriesName, match?.canonicalIssueNumber,
                                   match?.matchedSeriesYearBegan.map(String.init), row.id])
            }
            inTransaction {
                // GCD frequently catalogs a same-named restart or legacy-numbering continuation as
                // an entirely distinct series id sharing one display name (e.g. Amazing Spider-Man
                // Vol. 1 vs Vol. 2), so backfilling the matched GCD series' own start year here is
                // what lets the volume-aware series link/reading-order/rename logic tell them
                // apart. `has_comicinfo` (not a plain "is volume already set" check) decides
                // whether this pass may touch it: when true, a comic's Volume came from its own
                // ComicInfo.xml and must never be overwritten by a GCD guess; when false (the
                // overwhelming majority of real libraries -- ComicInfo.xml is often present on
                // under 1% of files), the GCD match is the ONLY possible source of truth for this
                // field, so a corrected/retracted match on a later pass must always be allowed to
                // correct/clear a previous pass's guess, not leave it permanently stuck the first
                // time a match happened to exist.
                runBatch("""
                    UPDATE comics SET gcd_issue_id = ?, gcd_cover_date = ?, gcd_match_confidence = ?, gcd_match_reason = ?,
                           gcd_series_name = ?, gcd_issue_number = ?,
                           volume = CASE WHEN has_comicinfo = 1 THEN volume ELSE ? END
                    WHERE id = ?
                    """, rows: updateRows)
            }
        }
    }

    func autoPopulateSeriesLinksFromGCD(store: OfflineMetadataStore = .shared) {
        let bonds = store.allSeriesBonds()
        guard !bonds.isEmpty else { return }
        queue.sync {
            let librarySeries: [SeriesContinuity.LibrarySeries] = rows(
                "SELECT DISTINCT publisher, series FROM comics WHERE deleted_at IS NULL"
            ) { s in SeriesContinuity.LibrarySeries(publisher: colText(s, 0) ?? "Unknown", series: colText(s, 1) ?? "General") }

            let proposals = SeriesContinuity.proposeLinks(bonds: bonds, librarySeries: librarySeries)
            guard !proposals.isEmpty else { return }

            // Precompute the already-linked set and track the next sequence number locally
            // instead of re-querying COUNT(*)/MAX(sequence_order) once per bond -- both were
            // constant across the whole loop except for links this same loop just inserted,
            // which the local Set/counter accounts for directly.
            var alreadyLinked = Set(rows("SELECT child_publisher, child_series FROM series_links") { s in
                "\(colText(s, 0) ?? ""):\(colText(s, 1) ?? "")"
            })
            var nextSeq = scalarInt("SELECT COALESCE(MAX(sequence_order), 0) + 1 FROM series_links")

            var insertRows: [[Any?]] = []
            for proposal in proposals {
                let key = "\(proposal.child.publisher):\(proposal.child.series)"
                guard !alreadyLinked.contains(key) else { continue }
                insertRows.append([proposal.parent.publisher, proposal.parent.series,
                                    proposal.child.publisher, proposal.child.series, nextSeq])
                alreadyLinked.insert(key)
                nextSeq += 1
            }
            inTransaction {
                runBatch("""
                    INSERT OR IGNORE INTO series_links
                        (parent_publisher, parent_series, child_publisher, child_series, sequence_order, source)
                    VALUES (?, ?, ?, ?, ?, 'gcd')
                    """, rows: insertRows)
            }
        }
    }

    func setReadingOrderOverride(comicId: Int64, position: Int, reason: String = "Manually placed") {
        queue.sync {
            _ = run("""
                INSERT OR REPLACE INTO reading_order_overrides (comic_id, position, reason) VALUES (?, ?, ?)
                """, args: [comicId, position, reason])
        }
    }

    func clearReadingOrderOverride(comicId: Int64) {
        queue.sync {
            _ = run("DELETE FROM reading_order_overrides WHERE comic_id = ?", args: [comicId])
        }
    }

    func clearAllReadingOrderOverrides() {
        queue.sync { _ = run("DELETE FROM reading_order_overrides") }
    }

    struct MetadataConflictInput {
        let comicId: Int64
        let field: String   // "series" | "publisher" | "issue_number"
        let current: String?
        let proposed: String?
        let source: String
    }

    /// Re-detecting the same (comic, field) conflict updates the existing row and resets it to
    /// 'pending' -- a stale dismissal must not permanently hide a disagreement that's still real
    /// (and possibly changed) on a later pass.
    func upsertMetadataConflicts(_ items: [MetadataConflictInput]) {
        guard !items.isEmpty else { return }
        _ = queue.sync {
            inTransaction {
                runBatch("""
                    INSERT INTO metadata_conflicts (comic_id, field, current_value, proposed_value, proposed_source)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(comic_id, field) DO UPDATE SET
                        current_value = excluded.current_value,
                        proposed_value = excluded.proposed_value,
                        proposed_source = excluded.proposed_source,
                        status = 'pending',
                        resolved_at = NULL
                    """, rows: items.map { [$0.comicId, $0.field, $0.current, $0.proposed, $0.source] })
            }
        }
    }

    func pendingMetadataConflicts() -> [(conflict: MetadataConflict, comic: Comic)] {
        queue.sync {
            struct Raw {
                let id: Int64; let comicId: Int64; let field: String
                let current: String?; let proposed: String?; let source: String
                let detectedAt: String; let status: String
            }
            let conflicts: [Raw] = rows("""
                SELECT mc.id, mc.comic_id, mc.field, mc.current_value, mc.proposed_value,
                       mc.proposed_source, mc.detected_at, mc.status
                FROM metadata_conflicts mc
                JOIN comics c ON c.id = mc.comic_id
                WHERE mc.status = 'pending' AND c.deleted_at IS NULL
                ORDER BY mc.detected_at DESC
                """) { s in
                Raw(id: colInt64(s, 0), comicId: colInt64(s, 1), field: colText(s, 2) ?? "",
                    current: colText(s, 3), proposed: colText(s, 4), source: colText(s, 5) ?? "",
                    detectedAt: colText(s, 6) ?? "", status: colText(s, 7) ?? "pending")
            }
            guard !conflicts.isEmpty else { return [] }
            let comicIds = Set(conflicts.map(\.comicId))
            let placeholders = comicIds.map { _ in "?" }.joined(separator: ",")
            let comics: [Comic] = rows("\(comicSelect) WHERE c.id IN (\(placeholders))",
                                        args: Array(comicIds).map { $0 as Any? }, map: comicRow)
            let comicsById = Dictionary(uniqueKeysWithValues: comics.map { ($0.id, $0) })
            return conflicts.compactMap { r in
                guard let comic = comicsById[r.comicId] else { return nil }
                return (MetadataConflict(id: r.id, comicId: r.comicId, field: r.field, currentValue: r.current,
                                          proposedValue: r.proposed, proposedSource: r.source,
                                          detectedAt: r.detectedAt, status: r.status), comic)
            }
        }
    }

    /// `apply`: writes the proposed value to `comics` and marks `meta_edited = 1` -- applying a
    /// conflict is itself a deliberate user choice, so it earns the same protection any other
    /// manual correction gets. `dismiss`: only updates the conflict's own status; `comics` is
    /// untouched, the current value stands.
    func resolveMetadataConflict(id: Int64, apply: Bool) {
        queue.sync {
            guard let row = rows("SELECT comic_id, field, proposed_value FROM metadata_conflicts WHERE id = ?",
                                  args: [id], map: { s in
                (colInt64(s, 0), colText(s, 1) ?? "", colText(s, 2))
            }).first else { return }
            let (comicId, field, proposed) = row
            if apply {
                let columns = ["series": "series", "publisher": "publisher", "issue_number": "issue_number"]
                guard let column = columns[field] else { return }
                _ = run("UPDATE comics SET \(column) = ?, meta_edited = 1 WHERE id = ?", args: [proposed, comicId])
                _ = run("UPDATE metadata_conflicts SET status = 'applied', resolved_at = CURRENT_TIMESTAMP WHERE id = ?", args: [id])
            } else {
                _ = run("UPDATE metadata_conflicts SET status = 'dismissed', resolved_at = CURRENT_TIMESTAMP WHERE id = ?", args: [id])
            }
        }
    }

    // MARK: - Existing-library import-priority audit (one-time, post-upgrade)

    private static let importPriorityAuditMigrationName = "importPriorityAuditV1"

    func hasCompletedImportPriorityAudit() -> Bool {
        queue.sync { scalarInt("SELECT COUNT(*) FROM migrations WHERE name = ?", args: [Self.importPriorityAuditMigrationName]) > 0 }
    }

    func markImportPriorityAuditComplete() {
        queue.sync { _ = run("INSERT OR IGNORE INTO migrations (name) VALUES (?)", args: [Self.importPriorityAuditMigrationName]) }
    }

    /// Rows that predate the raw-fact mirror columns (added well after `has_comicinfo` already
    /// existed) -- these are exactly the comics whose series/publisher were decided under the old
    /// folder/filename-first priority, with no record of what their own ComicInfo.xml said.
    func pendingImportPriorityAuditPaths() -> [(id: Int64, path: String)] {
        queue.sync {
            rows("SELECT id, file_path FROM comics WHERE has_comicinfo = 1 AND comicinfo_series IS NULL AND deleted_at IS NULL")
                { (colInt64($0, 0), colText($0, 1) ?? "") }
        }
    }

    struct IdentitySnapshot { let series: String?; let publisher: String?; let metaEdited: Bool }

    func identitySnapshots(for ids: [Int64]) -> [Int64: IdentitySnapshot] {
        guard !ids.isEmpty else { return [:] }
        return queue.sync {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let pairs: [(Int64, IdentitySnapshot)] = rows(
                "SELECT id, series, publisher, meta_edited FROM comics WHERE id IN (\(placeholders))",
                args: ids.map { $0 as Any? }
            ) { s in
                (colInt64(s, 0), IdentitySnapshot(series: colText(s, 1), publisher: colText(s, 2), metaEdited: colInt(s, 3) != 0))
            }
            return Dictionary(uniqueKeysWithValues: pairs)
        }
    }

    func updateComicInfoMirrors(_ items: [(id: Int64, comicInfoSeries: String?, comicInfoPublisher: String?)]) {
        guard !items.isEmpty else { return }
        _ = queue.sync {
            inTransaction {
                runBatch("UPDATE comics SET comicinfo_series = ?, comicinfo_publisher = ? WHERE id = ?",
                         rows: items.map { [$0.comicInfoSeries, $0.comicInfoPublisher, $0.id] })
            }
        }
    }

    struct SeriesLink {
        let id: Int64
        let parentPublisher: String; let parentSeries: String; let parentVolume: String?
        let childPublisher: String; let childSeries: String; let childVolume: String?
        let sequenceOrder: Int
        let source: String
    }

    func seriesLinks() -> [SeriesLink] {
        queue.sync {
            rows("""
                SELECT id, parent_publisher, parent_series, parent_volume,
                       child_publisher, child_series, child_volume, sequence_order, source
                FROM series_links ORDER BY sequence_order
                """) { s in
                SeriesLink(id: colInt64(s, 0), parentPublisher: colText(s, 1) ?? "", parentSeries: colText(s, 2) ?? "",
                           parentVolume: colText(s, 3), childPublisher: colText(s, 4) ?? "", childSeries: colText(s, 5) ?? "",
                           childVolume: colText(s, 6), sequenceOrder: colInt(s, 7), source: colText(s, 8) ?? "manual")
            }
        }
    }

    /// Combines publisher+series+volume into one key with volume-aware equality -- NULL and ""
    /// (no volume tag at all) are treated identically, matching the same COALESCE(...,'')
    /// convention used for `comics.volume` everywhere else (groupKey, series_group, etc.).
    private static func seriesVolumeKey(publisher: String, series: String, volume: String?) -> String {
        "\(publisher):\(series):\(volume?.isEmpty == false ? volume! : "")"
    }

    @discardableResult
    func addSeriesLink(parentPublisher: String, parentSeries: String, parentVolume: String? = nil,
                       childPublisher: String, childSeries: String, childVolume: String? = nil,
                       source: String = "manual") -> Bool {
        queue.sync {
            let nextSeq = scalarInt("SELECT COALESCE(MAX(sequence_order), 0) + 1 FROM series_links")
            let before = scalarInt("""
                SELECT COUNT(*) FROM series_links
                WHERE child_publisher = ? AND child_series = ? AND COALESCE(NULLIF(child_volume,''),'') = COALESCE(NULLIF(?,''),'')
                """, args: [childPublisher, childSeries, childVolume])
            guard before == 0 else { return false }

            let childKey = Self.seriesVolumeKey(publisher: childPublisher, series: childSeries, volume: childVolume)
            var ancestor: String? = Self.seriesVolumeKey(publisher: parentPublisher, series: parentSeries, volume: parentVolume)
            var hops = 0
            while let current = ancestor, hops < 100 {
                if current == childKey { return false }
                ancestor = scalarText("""
                    SELECT parent_publisher || ':' || parent_series || ':' || COALESCE(NULLIF(parent_volume,''),'')
                    FROM series_links
                    WHERE child_publisher || ':' || child_series || ':' || COALESCE(NULLIF(child_volume,''),'') = ?
                    """, args: [current]
                )
                hops += 1
            }

            _ = run("""
                INSERT INTO series_links (parent_publisher, parent_series, parent_volume,
                                           child_publisher, child_series, child_volume, sequence_order, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, args: [parentPublisher, parentSeries, parentVolume, childPublisher, childSeries, childVolume, nextSeq, source])
            return true
        }
    }

    func removeSeriesLink(childPublisher: String, childSeries: String, childVolume: String? = nil) {
        queue.sync {
            _ = run("""
                DELETE FROM series_links
                WHERE child_publisher = ? AND child_series = ? AND COALESCE(NULLIF(child_volume,''),'') = COALESCE(NULLIF(?,''),'')
                """, args: [childPublisher, childSeries, childVolume])
        }
    }

    func seriesLinkCycles() -> [[String]] {
        queue.sync { _seriesLinkCyclesUnlocked() }
    }

    func breakSeriesLinkCycles() {
        queue.sync {
            for cycle in _seriesLinkCyclesUnlocked() {
                let members = Set(cycle)
                guard let toBreak: (child: String, seq: Int) = rows(
                    """
                    SELECT child_publisher || ':' || child_series || ':' || COALESCE(NULLIF(child_volume,''),''), sequence_order
                    FROM series_links ORDER BY sequence_order DESC
                    """,
                    map: { s in (colText(s, 0) ?? "", colInt(s, 1)) }
                ).first(where: { members.contains($0.child) }) else { continue }
                let parts = toBreak.child.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                _ = run("""
                    DELETE FROM series_links
                    WHERE child_publisher = ? AND child_series = ? AND COALESCE(NULLIF(child_volume,''),'') = ?
                    """, args: [parts[0], parts[1], parts[2]])
            }
        }
    }

    private func _seriesLinkCyclesUnlocked() -> [[String]] {
        let links: [(parentKey: String, childKey: String)] = rows("""
            SELECT parent_publisher, parent_series, COALESCE(NULLIF(parent_volume,''),''),
                   child_publisher, child_series, COALESCE(NULLIF(child_volume,''),'')
            FROM series_links
            """
        ) { s in
            ("\(colText(s, 0) ?? ""):\(colText(s, 1) ?? ""):\(colText(s, 2) ?? "")",
             "\(colText(s, 3) ?? ""):\(colText(s, 4) ?? ""):\(colText(s, 5) ?? "")")
        }
        return SeriesContinuity.findCycles(links: links)
    }

    func allSeriesNames() -> [(publisher: String, series: String)] {
        queue.sync {
            rows("""
                SELECT DISTINCT publisher, series FROM comics
                WHERE deleted_at IS NULL ORDER BY series
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General") }
        }
    }

    /// Distinct (publisher, series, volume) triples -- unlike `allSeriesNames()`, this tells two
    /// differently-volumed runs of the same Series name apart (e.g. Amazing Spider-Man Vol. 1 vs
    /// Vol. 2), which is what the series-link picker needs to offer them as separate candidates.
    func allSeriesVolumes() -> [(publisher: String, series: String, volume: String?)] {
        queue.sync {
            rows("""
                SELECT DISTINCT publisher, series, volume FROM comics
                WHERE deleted_at IS NULL ORDER BY series, volume
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colText(s, 2)) }
        }
    }

    func seriesWithMultipleFirstIssues() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT publisher, series, COUNT(*) FROM comics
                WHERE deleted_at IS NULL AND CAST(NULLIF(issue_number, '') AS REAL) = 1
                      AND comic_type(issue_number, title, series, format) = 'regular'
                GROUP BY publisher, series HAVING COUNT(*) > 1
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

    func seriesNeedingSpecialReposition() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT publisher, series, COUNT(*) FROM comics
                WHERE deleted_at IS NULL AND reading_order_confidence = 0
                GROUP BY publisher, series HAVING COUNT(*) > 0
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

    func seriesWithNumberingGaps() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                WITH nums AS (
                    SELECT DISTINCT publisher, series, CAST(issue_number AS INTEGER) AS n
                    FROM comics
                    WHERE deleted_at IS NULL AND issue_number GLOB '[0-9]*'
                          AND comic_type(issue_number, title, series, format) = 'regular'
                ),
                ranked AS (
                    SELECT publisher, series, n,
                           LAG(n) OVER (PARTITION BY publisher, series ORDER BY n) AS prev
                    FROM nums
                )
                SELECT publisher, series, COUNT(*) FROM ranked
                WHERE prev IS NOT NULL AND n - prev > 1
                GROUP BY publisher, series
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

    func seriesWithMultipleVolumes() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT publisher, series, COUNT(DISTINCT volume) FROM comics
                WHERE deleted_at IS NULL AND volume IS NOT NULL AND volume != ''
                GROUP BY publisher, series HAVING COUNT(DISTINCT volume) > 1
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

    func missingComicInfoCount() -> Int {
        queue.sync { scalarInt("SELECT COUNT(*) FROM comics WHERE deleted_at IS NULL AND has_comicinfo = 0") }
    }

    func corruptArchiveCount() -> Int {
        queue.sync { scalarInt("SELECT COUNT(*) FROM comics WHERE deleted_at IS NULL AND page_count = 0") }
    }

    func seriesWithNumberingMismatches() -> [(publisher: String, series: String, count: Int)] {
        queue.sync {
            rows("""
                SELECT a.publisher, a.series, COUNT(*) FROM comics a
                JOIN comics b ON a.publisher = b.publisher AND a.series = b.series AND a.id < b.id
                WHERE a.deleted_at IS NULL AND b.deleted_at IS NULL
                      AND a.issue_number IS NOT NULL AND b.issue_number IS NOT NULL
                      AND CAST(a.issue_number AS REAL) = CAST(b.issue_number AS REAL)
                      AND a.issue_number != b.issue_number
                      AND comic_type(a.issue_number, a.title, a.series, a.format) = 'regular'
                      AND comic_type(b.issue_number, b.title, b.series, b.format) = 'regular'
                GROUP BY a.publisher, a.series
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colInt(s, 2)) }
        }
    }

    private func comicRow(_ s: OpaquePointer) -> Comic {
        Comic(
            id: colInt64(s, 0), title: colText(s, 1) ?? "", filePath: colText(s, 2) ?? "",
            publisher: colText(s, 3) ?? "Unknown", character: colText(s, 4),
            series: colText(s, 5) ?? "General", issueNumber: colText(s, 6),
            pageCount: colInt(s, 7), writer: colText(s, 8), penciller: colText(s, 9),
            year: sqlite3_column_type(s, 10) != SQLITE_NULL ? colInt(s, 10) : nil,
            volume: colText(s, 30), format: colText(s, 31),
            storyArc: colText(s, 11), languageIso: colText(s, 12), notes: colText(s, 13),
            addedAt: colText(s, 14) ?? "", deletedAt: colText(s, 15),
            position: colInt(s, 16), fileHash: colText(s, 17),
            progress: colInt(s, 18), lastRead: colText(s, 19),
            rating: colInt(s, 20),
            review: colText(s, 23),
            isFavorite: colBool(s, 21), inReadingList: colBool(s, 22),
            readingOrderPosition: sqlite3_column_type(s, 24) != SQLITE_NULL ? colInt(s, 24) : nil,
            readingOrderConfidence: sqlite3_column_type(s, 25) != SQLITE_NULL ? colInt(s, 25) : nil,
            readingOrderReason: colText(s, 26),
            gcdMatchConfidence: sqlite3_column_type(s, 27) != SQLITE_NULL ? colInt(s, 27) : nil,
            gcdSeriesName: colText(s, 28), gcdIssueNumber: colText(s, 29)
        )
    }

    private let comicSelect = """
        SELECT c.id, c.title, c.file_path, c.publisher, c.character, c.series,
               c.issue_number, c.page_count, c.writer, c.penciller, c.year,
               c.story_arc, c.language_iso, c.notes, c.added_at, c.deleted_at,
               COALESCE(c.position, c.id), c.file_hash,
               COALESCE(rp.current_page, 0) as progress, rp.last_read,
               COALESCE(r.rating, 0) as rating,
               (f.comic_id IS NOT NULL) as is_favorite,
               (rl.comic_id IS NOT NULL) as in_reading_list,
               r.review, c.reading_order_position, c.reading_order_confidence, c.reading_order_reason,
               c.gcd_match_confidence, c.gcd_series_name, c.gcd_issue_number, c.volume, c.format
        FROM comics c
        LEFT JOIN reading_progress rp ON c.id = rp.comic_id
        LEFT JOIN ratings r           ON c.id = r.comic_id
        LEFT JOIN favorites f         ON c.id = f.comic_id
        LEFT JOIN reading_list rl     ON c.id = rl.comic_id
    """

    enum ReadingOrderMode: String, CaseIterable, Identifiable {
        case filename = "Filename", legacyNumber = "Legacy Number",
             publicationDate = "Publication Date", comicInfoOrder = "ComicInfo Order",
             intelligent = "Intelligent Reading Order"
        var id: String { rawValue }

        static var current: ReadingOrderMode {
            ReadingOrderMode(rawValue: UserDefaults.standard.string(forKey: "readingOrderMode") ?? "") ?? .intelligent
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case publisher = "Publisher", title = "Title", dateAdded = "Recently Added",
             rating = "Top Rated", progress = "Most Read", manual = "Custom",
             year = "Year", storyArc = "Story Arc", pageCount = "Page Count",
             dateRead = "Recently Read", writer = "Writer"
        var id: String { rawValue }
        var clause: String {
            switch self {

            case .publisher: return "c.publisher, c.series, COALESCE(c.reading_order_position, c.position, is_special_issue(c.issue_number, c.title, c.series) * \(ComicSortClassifier.specialBandOffset) + c.id), c.title"
            case .title:     return "c.title"
            case .dateAdded: return "c.added_at DESC"
            case .rating:    return "COALESCE(r.rating, 0) DESC, c.title"
            case .progress:  return "COALESCE(rp.current_page, 0) DESC, c.title"
            case .manual:    return "COALESCE(c.reading_order_position, c.position, c.id), c.title"
            case .year:      return "COALESCE(c.year, 0) DESC, c.title"
            case .storyArc:  return "COALESCE(c.story_arc, ''), c.title"
            case .pageCount: return "c.page_count DESC, c.title"
            case .dateRead:  return "COALESCE(rp.last_read, '') DESC, c.title"
            case .writer:    return "COALESCE(c.writer, ''), c.title"
            }
        }
    }

    func allComics(publisher: String? = nil, character: String? = nil, series: String? = nil,
                   search: String? = nil, sortOrder: SortOrder = .publisher,
                   favoritesOnly: Bool = false, readingListOnly: Bool = false,
                   nullCharacterOnly: Bool = false, tag: String? = nil) -> [Comic] {
        queue.sync {
            var conds = ["c.deleted_at IS NULL"]
            var args: [Any?] = []
            if let pub = publisher, pub != "All" { conds.append("c.publisher = ?"); args.append(pub) }
            if nullCharacterOnly { conds.append("c.character IS NULL") }
            else if let chr = character { conds.append("c.character = ?"); args.append(chr) }
            if let ser = series { conds.append("c.series = ?"); args.append(ser) }
            if let q = search, !q.isEmpty {
                conds.append("(c.title LIKE ? ESCAPE '\\' OR c.series LIKE ? ESCAPE '\\' OR c.publisher LIKE ? ESCAPE '\\' OR c.writer LIKE ? ESCAPE '\\' OR c.penciller LIKE ? ESCAPE '\\' OR c.character LIKE ? ESCAPE '\\')")
                let p = "%\(Self.likeEscaped(q))%"
                args += [p, p, p, p, p, p]
            }
            if favoritesOnly   { conds.append("f.comic_id IS NOT NULL") }
            if readingListOnly { conds.append("rl.comic_id IS NOT NULL") }
            if let tag {
                conds.append("c.id IN (SELECT ct.comic_id FROM comic_tags ct JOIN tags t ON ct.tag_id = t.id WHERE t.name = ?)")
                args.append(tag)
            }
            let sql = "\(comicSelect) WHERE \(conds.joined(separator: " AND ")) ORDER BY \(sortOrder.clause)"
            return rows(sql, args: args, map: comicRow)
        }
    }

    func comic(id: Int64) -> Comic? {
        queue.sync {
            rows("\(comicSelect) WHERE c.id = ? AND c.deleted_at IS NULL", args: [id], map: comicRow).first
        }
    }

    struct MetadataInspectorInfo {
        let comic: Comic
        let comicType: ComicType
        let legacyNumber: Double?
        let coverMonth: Int?
        let coverDay: Int?
        let comicInfoIssueNumber: String?
        let alternateNumber: String?
        let storyArcNumber: String?
        let seriesGroup: String?
        let gcdMatchReason: String?
        let hasComicInfo: Bool?
        let gcdMatchSource: String
        let duplicateMatchCount: Int
    }

    func metadataInspectorInfo(comicId: Int64) -> MetadataInspectorInfo? {
        queue.sync {
            guard let comic = rows("\(comicSelect) WHERE c.id = ? AND c.deleted_at IS NULL", args: [comicId], map: comicRow).first else {
                return nil
            }
            struct Extra {
                let coverMonth: Int?; let coverDay: Int?; let comicInfoIssueNumber: String?
                let alternateNumber: String?; let storyArcNumber: String?; let seriesGroup: String?
                let gcdMatchReason: String?; let hasComicInfo: Int?; let gcdMatchSource: String
            }
            guard let extra = rows("""
                SELECT cover_month, cover_day, comicinfo_issue_number, alternate_number,
                       story_arc_number, series_group, gcd_match_reason, has_comicinfo, gcd_match_source
                FROM comics WHERE id = ?
                """, args: [comicId], map: { s in
                Extra(coverMonth: sqlite3_column_type(s, 0) != SQLITE_NULL ? colInt(s, 0) : nil,
                      coverDay: sqlite3_column_type(s, 1) != SQLITE_NULL ? colInt(s, 1) : nil,
                      comicInfoIssueNumber: colText(s, 2), alternateNumber: colText(s, 3),
                      storyArcNumber: colText(s, 4), seriesGroup: colText(s, 5), gcdMatchReason: colText(s, 6),
                      hasComicInfo: sqlite3_column_type(s, 7) != SQLITE_NULL ? colInt(s, 7) : nil,
                      gcdMatchSource: colText(s, 8) ?? "auto")
            }).first else { return nil }

            let comicType = ReadingOrderEngine.classify(issueNumber: comic.issueNumber, title: comic.title,
                                                         series: comic.series, format: comic.format)
            let legacyNumber = ReadingOrderEngine.parseLegacyNumber(comic.issueNumber)

            return MetadataInspectorInfo(
                comic: comic, comicType: comicType, legacyNumber: legacyNumber,
                coverMonth: extra.coverMonth, coverDay: extra.coverDay,
                comicInfoIssueNumber: extra.comicInfoIssueNumber, alternateNumber: extra.alternateNumber,
                storyArcNumber: extra.storyArcNumber, seriesGroup: extra.seriesGroup,
                gcdMatchReason: extra.gcdMatchReason,
                hasComicInfo: extra.hasComicInfo.map { $0 != 0 },
                gcdMatchSource: extra.gcdMatchSource,
                duplicateMatchCount: _duplicateMatchCountUnlocked(for: comicId)
            )
        }
    }

    func filePath(forComicId id: Int64) -> String? {
        queue.sync {
            rows("SELECT file_path FROM comics WHERE id = ? AND deleted_at IS NULL", args: [id],
                 map: { colText($0, 0) ?? "" }).first
        }
    }

    /// Records a user's deliberate pick from the "Fix Match" picker -- the one place in the app
    /// where a GCD match is set by explicit human choice rather than `recomputeGCDMatches`' own
    /// automatic scoring. Sets `gcd_match_source = 'manual'` so no future rescan can silently
    /// revert it (see the guard added to `recomputeGCDMatches`'s own candidate query). Confidence
    /// is always 100 -- a human pick is definitionally certain, not a scored guess. Volume backfill
    /// mirrors the automatic path exactly: only touches `volume` when there's no real ComicInfo.xml
    /// tag to protect (`has_comicinfo = 0`), never overwrites a genuine Volume tag.
    func setManualGCDMatch(comicId: Int64, gcdIssueId: Int, seriesName: String, issueNumber: String,
                           coverDate: String?, seriesYearBegan: Int?) {
        queue.sync {
            _ = run("""
                UPDATE comics SET gcd_issue_id = ?, gcd_cover_date = ?, gcd_match_confidence = 100,
                       gcd_match_reason = 'Manually matched', gcd_series_name = ?, gcd_issue_number = ?,
                       gcd_match_source = 'manual',
                       volume = CASE WHEN has_comicinfo = 1 THEN volume ELSE ? END
                WHERE id = ?
                """, args: [gcdIssueId, coverDate, seriesName, issueNumber,
                            seriesYearBegan.map(String.init), comicId])
        }
    }

    /// `BackupService`'s restore path for a manual match -- deliberately does NOT touch `volume`
    /// the way `setManualGCDMatch` does, since a backup doesn't carry the matched series' own
    /// start year and blindly writing `NULL` here would silently clear a volume value the comic
    /// may have picked up from an unrelated automatic match since the backup was taken.
    func restoreManualGCDMatch(comicId: Int64, gcdIssueId: Int, seriesName: String?, issueNumber: String?, coverDate: String?) {
        queue.sync {
            _ = run("""
                UPDATE comics SET gcd_issue_id = ?, gcd_cover_date = ?, gcd_match_confidence = 100,
                       gcd_match_reason = 'Manually matched', gcd_series_name = ?, gcd_issue_number = ?,
                       gcd_match_source = 'manual'
                WHERE id = ?
                """, args: [gcdIssueId, coverDate, seriesName, issueNumber, comicId])
        }
    }

    /// Reverts a manual match back to automatic control -- clears the match entirely (rather than
    /// leaving the stale manual values in place) so the row honestly shows "unmatched" until the
    /// next `recomputeGCDMatches` pass re-evaluates it on its own.
    func clearManualGCDMatch(comicId: Int64) {
        queue.sync {
            _ = run("""
                UPDATE comics SET gcd_issue_id = NULL, gcd_cover_date = NULL, gcd_match_confidence = NULL,
                       gcd_match_reason = NULL, gcd_series_name = NULL, gcd_issue_number = NULL,
                       gcd_match_source = 'auto'
                WHERE id = ?
                """, args: [comicId])
        }
    }

    struct GCDManualMatchDetail {
        let comicId: Int64
        let gcdIssueId: Int
        let seriesName: String?
        let issueNumber: String?
        let coverDate: String?
    }

    /// Every comic whose current GCD match is a deliberate manual pick, not `recomputeGCDMatches`'
    /// own automatic guess -- used by `BackupService` to decide which comics need their match
    /// exported, since a manual pick is a user choice worth preserving across a restore while an
    /// automatic match is disposable derived data the next scan regenerates on its own.
    func manualGCDMatchDetails() -> [GCDManualMatchDetail] {
        queue.sync {
            rows("""
                SELECT id, gcd_issue_id, gcd_series_name, gcd_issue_number, gcd_cover_date
                FROM comics
                WHERE gcd_match_source = 'manual' AND deleted_at IS NULL AND gcd_issue_id IS NOT NULL
                """) { s in
                GCDManualMatchDetail(comicId: colInt64(s, 0), gcdIssueId: colInt(s, 1),
                                      seriesName: colText(s, 2), issueNumber: colText(s, 3), coverDate: colText(s, 4))
            }
        }
    }

    /// The ideal filename for one comic, computed with the exact same canonical-name/volume/title
    /// disambiguation logic the bulk Rename Files tool uses (`ComicFileNaming`), scoped to just
    /// this comic's (publisher, series) siblings rather than the whole library. Returns nil when
    /// the file's current name already matches -- i.e. nothing to fix.
    func proposedFilename(comicId: Int64) -> String? {
        queue.sync {
            guard let target = rows("\(comicSelect) WHERE c.id = ? AND c.deleted_at IS NULL",
                                     args: [comicId], map: comicRow).first else { return nil }
            let siblings = rows("\(comicSelect) WHERE c.publisher = ? AND c.series = ? AND c.deleted_at IS NULL",
                                 args: [target.publisher, target.series], map: comicRow)
            guard let ideal = ComicFileNaming.idealFilenames(for: siblings)[comicId] else { return nil }
            let currentName = URL(fileURLWithPath: target.filePath).lastPathComponent
            return currentName == ideal ? nil : ideal
        }
    }

    func inProgress(limit: Int = 20) -> [Comic] {
        queue.sync {
            rows("""
                \(comicSelect)
                WHERE c.deleted_at IS NULL AND rp.current_page > 0
                  AND (c.page_count = 0 OR rp.current_page < c.page_count - 2)
                ORDER BY rp.last_read DESC LIMIT ?
            """, args: [limit], map: comicRow)
        }
    }

    func publishers() -> [String] {
        queue.sync {
            rows("""
                SELECT DISTINCT c.publisher FROM comics c
                LEFT JOIN publisher_order po ON po.publisher = c.publisher
                WHERE c.deleted_at IS NULL AND c.publisher IS NOT NULL
                ORDER BY COALESCE(po.position, 999999), c.publisher
                """, map: { colText($0, 0) ?? "" })
        }
    }

    func reorderPublishers(orderedPublishers: [String]) {
        guard !orderedPublishers.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for (idx, pub) in orderedPublishers.enumerated() {
                _ = run("INSERT OR REPLACE INTO publisher_order (publisher, position) VALUES (?,?)",
                        args: [pub, idx])
            }
            exec("COMMIT")
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
        /// Raw-fact mirrors: what ComicInfo.xml/the folder actually said, independent of which one
        /// won for the primary series/publisher columns above -- lets a priority decision made at
        /// import time be revisited later instead of being permanently lost. See
        /// `ComicIdentityResolver`.
        var comicInfoSeries: String? = nil
        var comicInfoPublisher: String? = nil
        var folderSeries: String? = nil
        var folderPublisher: String? = nil
        /// Which raw-fact source actually won for series/publisher/issueNumber above -- used to
        /// label a metadata conflict with where the proposed value came from (e.g. "ComicInfo.xml"
        /// vs "folder"), not persisted on `comics` itself.
        var seriesSource: String = ComicIdentityResolver.defaultSource
        var publisherSource: String = ComicIdentityResolver.defaultSource
        var issueNumberSource: String = ComicIdentityResolver.defaultSource
    }

    /// The placeholder values the scanner itself writes when a source has nothing real to offer --
    /// never worth protecting as if they were a genuine prior value.
    private static let identityPlaceholders: Set<String> = ["general", "unknown"]

    /// Nil if `current` is empty/a placeholder, or if it doesn't actually disagree with
    /// `proposed` (after case/whitespace-insensitive comparison) -- i.e. nil means "safe to
    /// auto-apply `proposed`, nothing worth flagging." Shared with `LibraryScanner`'s existing-
    /// library audit migration, so both use exactly the same disagreement rule.
    static func detectMetadataConflict(
        field: String, current: String?, proposed: String?, source: String, comicId: Int64
    ) -> MetadataConflictInput? {
        guard let current else { return nil }
        let normalizedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedCurrent.isEmpty, !identityPlaceholders.contains(normalizedCurrent) else { return nil }
        let normalizedProposed = (proposed ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedCurrent != normalizedProposed else { return nil }
        return MetadataConflictInput(comicId: comicId, field: field, current: current, proposed: proposed, source: source)
    }

    func batchInsert(_ comics: [ComicInsert]) {
        guard !comics.isEmpty else { return }
        // `upsertMetadataConflicts` takes `queue` itself -- collected here and applied AFTER this
        // function's own `queue.sync` block returns, never from inside it, or a nested `queue.sync`
        // on this serial queue would deadlock.
        let conflicts: [MetadataConflictInput] = queue.sync {
            // If any of this batch's paths already have a row with meta_edited = 0, compare the
            // newly-resolved series/publisher/issue_number against what's already there instead of
            // blindly overwriting it -- a real disagreement (not a placeholder being filled in for
            // the first time) gets flagged for review instead of silently applied in either
            // direction. Empty/cheap on a normal new-files-only scan, where none of these paths
            // exist yet.
            struct Existing { let id: Int64; let series: String?; let publisher: String?; let issueNumber: String?; let metaEdited: Bool }
            let paths = comics.map(\.filePath)
            let placeholders = paths.map { _ in "?" }.joined(separator: ",")
            let existingByPath: [String: Existing] = Dictionary(uniqueKeysWithValues: rows(
                "SELECT file_path, id, series, publisher, issue_number, meta_edited FROM comics WHERE file_path IN (\(placeholders))",
                args: paths.map { $0 as Any? }
            ) { s in
                (colText(s, 0) ?? "", Existing(id: colInt64(s, 1), series: colText(s, 2), publisher: colText(s, 3),
                                                issueNumber: colText(s, 4), metaEdited: colInt(s, 5) != 0))
            })

            var conflicts: [MetadataConflictInput] = []
            let resolvedComics: [ComicInsert] = comics.map { c in
                guard let existing = existingByPath[c.filePath], !existing.metaEdited else { return c }
                var adjusted = c
                if let conflict = Self.detectMetadataConflict(field: "series", current: existing.series, proposed: c.series,
                                                                source: c.seriesSource, comicId: existing.id) {
                    conflicts.append(conflict)
                    adjusted.series = existing.series ?? c.series
                }
                if let conflict = Self.detectMetadataConflict(field: "publisher", current: existing.publisher, proposed: c.publisher,
                                                                source: c.publisherSource, comicId: existing.id) {
                    conflicts.append(conflict)
                    adjusted.publisher = existing.publisher ?? c.publisher
                }
                if let conflict = Self.detectMetadataConflict(field: "issue_number", current: existing.issueNumber, proposed: c.issueNumber,
                                                                source: c.issueNumberSource, comicId: existing.id) {
                    conflicts.append(conflict)
                    adjusted.issueNumber = existing.issueNumber
                }
                return adjusted
            }

            _ = inTransaction {
                // Each of these two statements is identical text across every comic in the
                // batch -- prepared once and reused across all rows instead of `_insertRow`'s
                // former per-comic prepare/finalize, which mattered for first-time imports of
                // large libraries (chunks of up to 100 comics per flush, potentially many chunks).
                let insertRows: [[Any?]] = resolvedComics.map { c in
                    [c.title, c.filePath, c.publisher, c.character,
                     c.series, c.issueNumber, c.pageCount, c.writer,
                     c.penciller, c.year.map { Int64($0) }, c.storyArc,
                     c.languageIso, c.fileHash, c.coverMonth.map { Int64($0) },
                     c.coverDay.map { Int64($0) }, c.alternateNumber, c.storyArcNumber, c.seriesGroup, c.comicInfoIssueNumber,
                     c.volume, c.format, c.hasComicInfo.map { $0 ? Int64(1) : Int64(0) },
                     c.comicInfoSeries, c.comicInfoPublisher, c.folderSeries, c.folderPublisher]
                }
                // ON CONFLICT (not OR IGNORE): file_path is UNIQUE, and a soft-deleted comic keeps
                // its row (deleted_at set, never removed) forever at that same path. If the file
                // later reappears after being wrongly marked stale (e.g. a flaky/waking external
                // drive during a scan), INSERT OR IGNORE would silently no-op on the UNIQUE
                // conflict -- the comic would never come back, permanently orphaned. Reviving the
                // SAME row on conflict instead means its reading_progress/ratings/tags/list-
                // memberships (all keyed by this comic_id) are still correctly attached -- a plain
                // "delete and re-insert" would have orphaned all of that. added_at and position
                // are deliberately left untouched: a revival isn't a new addition. The folder-
                // derived identity columns (matching `folderDerivedColumns`, plus issue_number)
                // are gated behind meta_edited like every other write path touches them -- without
                // this, a user's manual correction survives right up until the file goes briefly
                // missing (e.g. a flaky external drive) and reappears, at which point the revival
                // would have silently reset it back to the raw filename/folder-parsed guess.
                let ok1 = runBatch("""
                    INSERT INTO comics
                        (title, file_path, publisher, character, series, issue_number,
                         page_count, writer, penciller, year, story_arc, language_iso, file_hash, cover_month,
                         cover_day, alternate_number, story_arc_number, series_group, comicinfo_issue_number, volume,
                         format, has_comicinfo, comicinfo_series, comicinfo_publisher, folder_series, folder_publisher)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(file_path) DO UPDATE SET
                        deleted_at = NULL, scan_retry_count = 0,
                        title = CASE WHEN comics.meta_edited = 0 THEN excluded.title ELSE comics.title END,
                        publisher = CASE WHEN comics.meta_edited = 0 THEN excluded.publisher ELSE comics.publisher END,
                        character = CASE WHEN comics.meta_edited = 0 THEN excluded.character ELSE comics.character END,
                        series = CASE WHEN comics.meta_edited = 0 THEN excluded.series ELSE comics.series END,
                        issue_number = CASE WHEN comics.meta_edited = 0 THEN excluded.issue_number ELSE comics.issue_number END,
                        page_count = excluded.page_count,
                        writer = excluded.writer, penciller = excluded.penciller, year = excluded.year,
                        story_arc = excluded.story_arc, language_iso = excluded.language_iso, file_hash = excluded.file_hash,
                        cover_month = excluded.cover_month, cover_day = excluded.cover_day,
                        alternate_number = excluded.alternate_number, story_arc_number = excluded.story_arc_number,
                        series_group = excluded.series_group, comicinfo_issue_number = excluded.comicinfo_issue_number,
                        volume = excluded.volume, format = excluded.format, has_comicinfo = excluded.has_comicinfo,
                        comicinfo_series = excluded.comicinfo_series, comicinfo_publisher = excluded.comicinfo_publisher,
                        folder_series = excluded.folder_series, folder_publisher = excluded.folder_publisher
                    """, rows: insertRows)

                // A revival (or a metadata refresh) can leave a comic's page_count smaller than
                // whatever page reading_progress last saved -- clamp it down so Stats/Continue
                // Reading stop treating stale out-of-range progress as "finished", and the reader
                // doesn't need to be the only place enforcing this.
                let clampRows: [[Any?]] = comics.map { [$0.filePath, $0.filePath, $0.filePath] }
                let ok2 = runBatch("""
                    UPDATE reading_progress SET current_page = MAX(0, (SELECT page_count FROM comics WHERE file_path = ?) - 1)
                    WHERE comic_id = (SELECT id FROM comics WHERE file_path = ?)
                      AND current_page > MAX(0, (SELECT page_count FROM comics WHERE file_path = ?) - 1)
                    """, rows: clampRows)
                return ok1 && ok2
            }
            return conflicts
        }
        if !conflicts.isEmpty { upsertMetadataConflicts(conflicts) }
    }

    func zeroPageCountPaths() -> [(id: Int64, path: String)] {
        queue.sync {
            rows("SELECT id, file_path FROM comics WHERE page_count = 0 AND deleted_at IS NULL AND scan_retry_count < 3",
                 map: { (colInt64($0, 0), colText($0, 1) ?? "") })
        }
    }

    func updatePageCount(comicId: Int64, count: Int) {
        queue.sync {
            _ = run("UPDATE comics SET page_count = ? WHERE id = ?", args: [count, comicId])
            // See _insertRow's matching comment -- a corrected page count can leave saved
            // progress out of range.
            _ = run("""
                UPDATE reading_progress SET current_page = MAX(0, ? - 1)
                WHERE comic_id = ? AND current_page > MAX(0, ? - 1)
                """, args: [count, comicId, count])
        }
    }

    func incrementScanRetryCount(comicId: Int64) {
        queue.sync { _ = run("UPDATE comics SET scan_retry_count = scan_retry_count + 1 WHERE id = ?", args: [comicId]) }
    }

    func resetScanRetryCounts() {
        queue.sync { _ = exec("UPDATE comics SET scan_retry_count = 0") }
    }

    func knownPaths() -> Set<String> {
        queue.sync { Set(rows("SELECT file_path FROM comics WHERE deleted_at IS NULL", map: { colText($0, 0) ?? "" })) }
    }

    /// Returns the id of a soft-deleted comic at this exact path, if one exists -- used to evict its
    /// (possibly stale/wrong) cached cover before the row is revived by a rescan.
    func softDeletedComicId(atPath path: String) -> Int64? {
        queue.sync {
            let id = scalarInt("SELECT id FROM comics WHERE file_path = ? AND deleted_at IS NOT NULL", args: [path])
            return id > 0 ? Int64(id) : nil
        }
    }

    func knownHashes() -> Set<String> {
        queue.sync {
            Set(rows("SELECT file_hash FROM comics WHERE file_hash IS NOT NULL AND deleted_at IS NULL",
                     map: { colText($0, 0) ?? "" }))
        }
    }

    func softDelete(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            var stmt: OpaquePointer?
            let sql = "UPDATE comics SET deleted_at = datetime('now') WHERE id IN (\(ph))"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            for (i, id) in ids.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), id) }
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

    func updateProgress(comicId: Int64, page: Int) {
        queue.sync {
            _ = run("""
            INSERT INTO reading_progress (comic_id, current_page, last_read)
            VALUES (?, ?, datetime('now'))
            ON CONFLICT(comic_id) DO UPDATE
              SET current_page = ?, last_read = datetime('now')
            """, args: [comicId, page, page])
        }
    }

    func updateProgress(_ updates: [(comicId: Int64, page: Int)]) {
        guard !updates.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for (comicId, page) in updates {
                _ = run("""
                INSERT INTO reading_progress (comic_id, current_page, last_read)
                VALUES (?, ?, datetime('now'))
                ON CONFLICT(comic_id) DO UPDATE
                  SET current_page = ?, last_read = datetime('now')
                """, args: [comicId, page, page])
            }
            exec("COMMIT")
        }
    }

    func setRating(_ comicId: Int64, rating: Int) {
        queue.sync {

            _ = run("""
                INSERT INTO ratings (comic_id, rating) VALUES (?,?)
                ON CONFLICT(comic_id) DO UPDATE SET rating = excluded.rating
            """, args: [comicId, rating])
            _logDiaryEntryUnlocked(comicId: comicId)
        }
    }

    /// Snapshots the current rating/review into `diary_entries`, called after every
    /// `setRating`/`setComicReview` write. Same-day edits collapse into the existing
    /// entry (rapid star-taps in one sitting shouldn't spam the diary); a genuinely new
    /// day always starts a new entry, marked `is_reread` if any prior entry exists.
    /// Must run already inside `queue.sync` — not itself queue-wrapped.
    private func _logDiaryEntryUnlocked(comicId: Int64) {
        guard let current: (rating: Int, review: String?) = rows(
            "SELECT rating, review FROM ratings WHERE comic_id = ?", args: [comicId],
            map: { s in (colInt(s, 0), colText(s, 1)) }
        ).first, current.rating > 0 else { return }

        // logged_at is stored as CURRENT_TIMESTAMP (UTC). Comparing raw date(...) without a
        // 'localtime' conversion collapses/splits entries on a UTC midnight boundary that has
        // nothing to do with the user's actual calendar day -- e.g. for US timezones, UTC
        // midnight falls in the late afternoon/evening local time, a common reading window,
        // so two ratings minutes apart could get split into two entries; conversely, in
        // timezones ahead of UTC, two ratings on different local days could collapse into one,
        // silently overwriting the earlier day's rating/review.
        let todayId: Int64? = rows(
            "SELECT id FROM diary_entries WHERE comic_id = ? AND date(logged_at, 'localtime') = date('now', 'localtime') ORDER BY id DESC LIMIT 1",
            args: [comicId], map: { colInt64($0, 0) }
        ).first

        if let todayId {
            _ = run("UPDATE diary_entries SET rating = ?, review = ? WHERE id = ?",
                    args: [current.rating, current.review, todayId])
        } else {
            let hasPriorEntry = scalarInt("SELECT COUNT(*) FROM diary_entries WHERE comic_id = ?", args: [comicId]) > 0
            _ = run("""
                INSERT INTO diary_entries (comic_id, rating, review, is_reread) VALUES (?,?,?,?)
            """, args: [comicId, current.rating, current.review, hasPriorEntry ? 1 : 0])
        }
    }

    func setComicNotes(_ comicId: Int64, notes: String?) {
        let text = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.sync {
            _ = run("UPDATE comics SET notes = ? WHERE id = ?",
                    args: [(text?.isEmpty == false) ? text : nil, comicId])
        }
    }

    func setComicReview(_ comicId: Int64, review: String?) {
        let text = review?.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.sync {
            _ = run("""
                INSERT INTO ratings (comic_id, rating, review) VALUES (?,COALESCE((SELECT rating FROM ratings WHERE comic_id=?),0),?)
                ON CONFLICT(comic_id) DO UPDATE SET review = excluded.review
            """, args: [comicId, comicId, (text?.isEmpty == false) ? text : nil])
            _logDiaryEntryUnlocked(comicId: comicId)
        }
    }

    func diaryEntries(limit: Int = 500) -> [DiaryEntry] {
        queue.sync {
            struct RawEntry { let id: Int64; let comicId: Int64; let rating: Int; let review: String?; let loggedAt: String; let isReread: Bool }
            let raw: [RawEntry] = rows("""
                SELECT id, comic_id, rating, review, logged_at, is_reread
                FROM diary_entries
                ORDER BY logged_at DESC, id DESC
                LIMIT ?
                """, args: [limit], map: { s in
                    RawEntry(id: colInt64(s, 0), comicId: colInt64(s, 1), rating: colInt(s, 2), review: colText(s, 3),
                             loggedAt: colText(s, 4) ?? "", isReread: colInt(s, 5) != 0)
                })
            guard !raw.isEmpty else { return [] }

            let comicIds = raw.map { $0.comicId }
            let placeholders = comicIds.map { _ in "?" }.joined(separator: ",")
            let comicsById: [Int64: Comic] = Dictionary(uniqueKeysWithValues:
                rows("\(comicSelect) WHERE c.id IN (\(placeholders)) AND c.deleted_at IS NULL",
                     args: comicIds, map: comicRow).map { ($0.id, $0) }
            )
            return raw.compactMap { entry in
                guard let comic = comicsById[entry.comicId] else { return nil }
                return DiaryEntry(id: entry.id, comic: comic, rating: entry.rating, review: entry.review,
                                   loggedAt: entry.loggedAt, isReread: entry.isReread)
            }
        }
    }

    func deleteDiaryEntry(id: Int64) {
        queue.sync { _ = run("DELETE FROM diary_entries WHERE id = ?", args: [id]) }
    }

    /// Restores a diary entry with an explicit historical `logged_at` -- distinct from
    /// `_logDiaryEntryUnlocked`, which always stamps the current time and collapses same-day
    /// edits together (the right behavior for a live rating change, wrong for replaying a
    /// backup's exact original entries).
    func restoreDiaryEntry(comicId: Int64, rating: Int, review: String?, isReread: Bool, loggedAt: String) {
        queue.sync {
            _ = run("""
                INSERT INTO diary_entries (comic_id, rating, review, is_reread, logged_at) VALUES (?,?,?,?,?)
                """, args: [comicId, rating, review, isReread ? 1 : 0, loggedAt])
        }
    }

    func allReadingOrderOverrides() -> [(filePath: String, position: Int, reason: String)] {
        queue.sync {
            rows("""
                SELECT c.file_path, o.position, o.reason
                FROM reading_order_overrides o JOIN comics c ON c.id = o.comic_id
                WHERE c.deleted_at IS NULL
                """) { s in
                (colText(s, 0) ?? "", colInt(s, 1), colText(s, 2) ?? "Manually placed")
            }
        }
    }

    func runsContaining(comicId: Int64) -> [Run] {
        queue.sync {
            rows("""
                SELECT r.id, r.title, COALESCE(r.description,''), COALESCE(r.rating,0), r.review, r.buy_link, r.created_at
                FROM runs r JOIN run_items ri ON ri.run_id = r.id
                WHERE ri.comic_id = ? ORDER BY r.created_at
            """, args: [comicId]) { r in
                Run(id: colInt64(r, 0), title: colText(r, 1) ?? "", description: colText(r, 2) ?? "",
                    rating: { let v = colInt(r, 3); return v > 0 ? v : nil }(),
                    review: colText(r, 4), buyLink: colText(r, 5), createdAt: colText(r, 6) ?? "")
            }
        }
    }

    func updateRun(id: Int64, title: String, description: String, buyLink: String?) {
        queue.sync {
            _ = run("UPDATE runs SET title = ?, description = ?, buy_link = ? WHERE id = ?",
                    args: [title, description, buyLink?.isEmpty == false ? buyLink : nil, id])
        }
    }

    func comicIdsInRun(runId: Int64) -> Set<Int64> {
        queue.sync {
            Set(rows("SELECT comic_id FROM run_items WHERE run_id = ?", args: [runId]) { colInt64($0, 0) })
        }
    }

    func listsContaining(comicId: Int64) -> [ComicList] {
        queue.sync {
            rows("""
                SELECT l.id, l.title, COALESCE(l.description,''), COALESCE(l.rating,0), l.review, l.created_at
                FROM lists l JOIN list_items li ON li.list_id = l.id
                WHERE li.comic_id = ? ORDER BY l.created_at
            """, args: [comicId]) { r in
                ComicList(id: colInt64(r, 0), title: colText(r, 1) ?? "", description: colText(r, 2) ?? "",
                          rating: { let v = colInt(r, 3); return v > 0 ? v : nil }(),
                          review: colText(r, 4), createdAt: colText(r, 5) ?? "")
            }
        }
    }

    func updateList(id: Int64, title: String, description: String) {
        queue.sync {
            _ = run("UPDATE lists SET title = ?, description = ? WHERE id = ?",
                    args: [title, description, id])
        }
    }

    func comicIdsInList(listId: Int64) -> Set<Int64> {
        queue.sync {
            Set(rows("SELECT comic_id FROM list_items WHERE list_id = ?", args: [listId]) { colInt64($0, 0) })
        }
    }

    func tierListsContaining(comicId: Int64) -> [TierList] {
        queue.sync {
            rows("""
                SELECT tl.id, tl.title, COALESCE(tl.description,''), tl.created_at
                FROM tier_lists tl JOIN tier_list_items tli ON tli.tier_list_id = tl.id
                WHERE tli.comic_id = ? ORDER BY tl.created_at
            """, args: [comicId]) { r in
                TierList(id: colInt64(r, 0), title: colText(r, 1) ?? "", description: colText(r, 2) ?? "",
                          createdAt: colText(r, 3) ?? "")
            }
        }
    }

    func updateTierList(id: Int64, title: String, description: String) {
        queue.sync {
            _ = run("UPDATE tier_lists SET title = ?, description = ? WHERE id = ?",
                    args: [title, description, id])
        }
    }

    func comicIdsInTierList(tierListId: Int64) -> Set<Int64> {
        queue.sync {
            Set(rows("SELECT comic_id FROM tier_list_items WHERE tier_list_id = ?", args: [tierListId]) { colInt64($0, 0) })
        }
    }

    func setFavorite(_ comicId: Int64, _ value: Bool) {
        queue.sync {
            if value { run("INSERT OR IGNORE INTO favorites (comic_id) VALUES (?)", args: [comicId]) }
            else      { run("DELETE FROM favorites WHERE comic_id = ?", args: [comicId]) }
        }
    }

    func setInReadingList(_ comicId: Int64, _ value: Bool) {
        queue.sync {
            if value { run("INSERT OR IGNORE INTO reading_list (comic_id) VALUES (?)", args: [comicId]) }
            else      { run("DELETE FROM reading_list WHERE comic_id = ?", args: [comicId]) }
        }
    }

    func setInReadingList(_ ids: [Int64], _ value: Bool) {
        guard !ids.isEmpty else { return }
        queue.sync {
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            let args = ids.map { $0 as Any? }
            if value {
                let values = ids.map { _ in "(?)" }.joined(separator: ",")
                _ = run("INSERT OR IGNORE INTO reading_list (comic_id) VALUES \(values)", args: args)
            } else {
                _ = run("DELETE FROM reading_list WHERE comic_id IN (\(ph))", args: args)
            }
        }
    }

    private static let folderDerivedColumns: Set<String> = ["title", "series", "publisher", "character"]

    func updateMeta(comicId: Int64, fields: [(String, Any?)]) {
        guard !fields.isEmpty else { return }
        queue.sync {
            var sets = fields.map { "\($0.0) = ?" }
            var args: [Any?] = fields.map { $0.1 }
            if fields.contains(where: { Self.folderDerivedColumns.contains($0.0) }) {
                sets.append("meta_edited = 1")
            }
            args.append(comicId)
            _ = run("UPDATE comics SET \(sets.joined(separator: ", ")) WHERE id = ?", args: args)
        }
    }

    func tags(for comicId: Int64) -> [Tag] {
        queue.sync {
            rows("SELECT t.id, t.name, t.category FROM tags t JOIN comic_tags ct ON t.id = ct.tag_id WHERE ct.comic_id = ? ORDER BY t.name",
                 args: [comicId]) { Tag(id: colInt64($0, 0), name: colText($0, 1) ?? "", category: colText($0, 2)) }
        }
    }

    func addTag(name: String, to comicId: Int64, category: TagCategory = .custom) {
        queue.sync {

            _ = run("INSERT OR IGNORE INTO tags (name, category) VALUES (?,?)", args: [name, category.rawValue])
            let resolvedId = scalarInt("SELECT id FROM tags WHERE name = ?", args: [name])
            guard resolvedId > 0 else { return }
            _ = run("INSERT OR IGNORE INTO comic_tags (comic_id, tag_id) VALUES (?,?)",
                    args: [comicId, Int64(resolvedId)])
        }
    }

    func comics(withPaths paths: [String]) -> [Comic] {
        guard !paths.isEmpty else { return [] }
        return queue.sync {
            let ph = paths.map { _ in "?" }.joined(separator: ",")
            return rows("\(comicSelect) WHERE c.file_path IN (\(ph)) AND c.deleted_at IS NULL",
                        args: paths.map { $0 as Any? }, map: comicRow)
        }
    }

    func removeTag(tagId: Int64, from comicId: Int64) {
        queue.sync {
            _ = run("DELETE FROM comic_tags WHERE comic_id = ? AND tag_id = ?", args: [comicId, tagId])
            _ = run("DELETE FROM tags WHERE id = ? AND (SELECT COUNT(*) FROM comic_tags WHERE tag_id = ?) = 0",
                    args: [tagId, tagId])
        }
    }

    func allComicPaths() -> [(id: Int64, path: String)] {
        queue.sync {
            rows("SELECT id, file_path FROM comics WHERE deleted_at IS NULL") { s in
                (id: self.colInt64(s, 0), path: self.colText(s, 1) ?? "")
            }
        }
    }

    func renameSeries(oldName: String, publisher: String?, newName: String) {
        queue.sync {
            // Keep any series_links row pointing at this series in sync too -- otherwise renaming
            // a series orphans its link (the stored name no longer matches anything in `comics`),
            // silently breaking whatever volume-aware reading-order chaining it was providing.
            // Wrapped in a transaction so a crash between the `comics` update and the
            // `series_links` updates can't leave them pointing at different series names.
            _ = inTransaction {
                if let pub = publisher, !pub.isEmpty, pub != "All" {
                    let ok1 = run("UPDATE comics SET series = ? WHERE series = ? AND publisher = ?",
                                   args: [newName, oldName, pub]) != -1
                    let ok2 = run("UPDATE series_links SET parent_series = ? WHERE parent_series = ? AND parent_publisher = ?",
                                   args: [newName, oldName, pub]) != -1
                    let ok3 = run("UPDATE series_links SET child_series = ? WHERE child_series = ? AND child_publisher = ?",
                                   args: [newName, oldName, pub]) != -1
                    return ok1 && ok2 && ok3
                } else {
                    let ok1 = run("UPDATE comics SET series = ? WHERE series = ?",
                                   args: [newName, oldName]) != -1
                    let ok2 = run("UPDATE series_links SET parent_series = ? WHERE parent_series = ?", args: [newName, oldName]) != -1
                    let ok3 = run("UPDATE series_links SET child_series = ? WHERE child_series = ?", args: [newName, oldName]) != -1
                    return ok1 && ok2 && ok3
                }
            }
        }
    }

    func seriesNameCollides(oldName: String, publisher: String?, newName: String) -> Bool {
        guard newName != oldName else { return false }
        return queue.sync {
            if let pub = publisher, !pub.isEmpty, pub != "All" {
                return scalarInt("SELECT COUNT(*) FROM comics WHERE series = ? AND publisher = ?",
                                  args: [newName, pub]) > 0
            }
            return scalarInt("SELECT COUNT(*) FROM comics WHERE series = ?", args: [newName]) > 0
        }
    }

    func bulkReassign(ids: [Int64], series: String?, publisher: String?) {
        guard !ids.isEmpty, series != nil || publisher != nil else { return }
        _ = queue.sync {
            inTransaction {
                var ok = true
                if let ser = series {
                    ok = runBatch("UPDATE comics SET series = ?, meta_edited = 1 WHERE id = ?",
                                   rows: ids.map { [ser, $0] })
                }
                if ok, let pub = publisher {
                    ok = runBatch("UPDATE comics SET publisher = ?, meta_edited = 1 WHERE id = ?",
                                   rows: ids.map { [pub, $0] })
                }
                return ok
            }
        }
    }

    func duplicateGroups() -> [[Comic]] {
        queue.sync {
            let flat = rows("""
                \(comicSelect)
                JOIN (
                    SELECT publisher, series, issue_number,
                           comic_type(issue_number, title, series, format) AS ctype
                    FROM comics
                    WHERE deleted_at IS NULL AND issue_number IS NOT NULL AND issue_number != ''
                    GROUP BY publisher, series, issue_number, ctype
                    HAVING COUNT(*) > 1
                ) dup ON dup.publisher = c.publisher AND dup.series = c.series
                     AND dup.issue_number = c.issue_number
                     AND dup.ctype = comic_type(c.issue_number, c.title, c.series, c.format)
                WHERE c.deleted_at IS NULL
                ORDER BY c.publisher, c.series, CAST(c.issue_number AS INTEGER),
                         comic_type(c.issue_number, c.title, c.series, c.format)
            """, map: comicRow)

            guard !flat.isEmpty else { return [] }
            var groups: [[Comic]] = []
            var currentKey: (String, String, String, ComicType)? = nil
            for comic in flat {
                let type = ReadingOrderEngine.classify(issueNumber: comic.issueNumber, title: comic.title, series: comic.series, format: comic.format)
                let key = (comic.publisher, comic.series, comic.issueNumber ?? "", type)
                if currentKey == nil || currentKey! != key {
                    groups.append([comic])
                    currentKey = key
                } else {
                    groups[groups.count - 1].append(comic)
                }
            }

            var result = groups.flatMap(splitByVolumeOrYear)

            let hashMatches: [Comic] = rows("""
                \(comicSelect)
                JOIN (
                    SELECT file_hash FROM comics
                    WHERE deleted_at IS NULL AND file_hash IS NOT NULL
                    GROUP BY file_hash HAVING COUNT(*) > 1
                ) dh ON dh.file_hash = c.file_hash
                WHERE c.deleted_at IS NULL
                ORDER BY c.file_hash
            """, map: comicRow)
            var byHash: [String: [Comic]] = [:]
            for comic in hashMatches { byHash[comic.fileHash ?? "", default: []].append(comic) }
            var knownGroupIdSets = Set(result.map { Set($0.map(\.id)) })
            for members in byHash.values where members.count > 1 {
                let idSet = Set(members.map(\.id))
                guard !knownGroupIdSets.contains(idSet) else { continue }
                result.append(members)
                knownGroupIdSets.insert(idSet)
            }

            return result
        }
    }

    func duplicateMatchCount(for comicId: Int64) -> Int {
        queue.sync { _duplicateMatchCountUnlocked(for: comicId) }
    }

    private func _duplicateMatchCountUnlocked(for comicId: Int64) -> Int {
        guard let comic = rows("\(comicSelect) WHERE c.id = ? AND c.deleted_at IS NULL", args: [comicId], map: comicRow).first else {
            return 0
        }
        let comicType = ReadingOrderEngine.classify(issueNumber: comic.issueNumber, title: comic.title,
                                                     series: comic.series, format: comic.format)
        let candidates: [Comic] = rows("""
            \(comicSelect)
            WHERE c.deleted_at IS NULL AND c.publisher = ? AND c.series = ? AND c.issue_number = ?
                  AND comic_type(c.issue_number, c.title, c.series, c.format) = ?
            """, args: [comic.publisher, comic.series, comic.issueNumber ?? "", comicType.rawValue], map: comicRow)
        let matchingBucket = splitByVolumeOrYear(candidates).first { $0.contains { $0.id == comicId } } ?? []
        var matchedIds = Set(matchingBucket.map(\.id))

        if let hash = comic.fileHash {
            let hashMatches = rows("SELECT id FROM comics WHERE deleted_at IS NULL AND file_hash = ?",
                                    args: [hash]) { colInt64($0, 0) }
            matchedIds.formUnion(hashMatches)
        }
        matchedIds.remove(comicId)
        return matchedIds.count
    }

    private func splitByVolumeOrYear(_ group: [Comic]) -> [[Comic]] {
        guard group.count > 1 else { return [group] }
        var buckets: [[Comic]] = []
        outer: for comic in group {
            for i in buckets.indices {
                let compatible = buckets[i].allSatisfy { existing in
                    if let v1 = comic.volume, let v2 = existing.volume, v1 != v2 { return false }
                    if let y1 = comic.year, let y2 = existing.year, abs(y1 - y2) > 1 { return false }
                    return true
                }
                if compatible {
                    buckets[i].append(comic)
                    continue outer
                }
            }
            buckets.append([comic])
        }
        return buckets.filter { $0.count > 1 }
    }

    func autoPlacedSpecialIssues() -> [Comic] {
        queue.sync {
            rows("""
                \(comicSelect)
                WHERE c.deleted_at IS NULL
                      AND c.reading_order_confidence IS NOT NULL
                      AND c.reading_order_confidence BETWEEN 1 AND 99
                ORDER BY c.publisher, c.series, c.reading_order_position, c.title
            """, map: comicRow)
        }
    }

    func reorderComics(orderedIds: [Int64]) {
        _ = queue.sync {
            inTransaction {
                let ok1 = runBatch("""
                    UPDATE comics SET position = ?, reading_order_position = ?,
                           reading_order_confidence = 100, reading_order_reason = 'Manually placed'
                    WHERE id = ?
                    """, rows: orderedIds.enumerated().map { [$0.offset, $0.offset, $0.element] })
                let ok2 = runBatch("""
                    INSERT OR REPLACE INTO reading_order_overrides (comic_id, position, reason) VALUES (?, ?, 'Manually placed')
                    """, rows: orderedIds.enumerated().map { [$0.element, $0.offset] })
                return ok1 && ok2
            }
        }
    }

    func allRuns() -> [Run] {
        queue.sync {
            let sql = """
                SELECT r.id, r.title, COALESCE(r.description,''), COALESCE(r.rating,0), r.review, r.buy_link, r.created_at,
                       COUNT(ri.id) as total,
                       SUM(CASE WHEN c.page_count > 1 AND COALESCE(rp.current_page,0) >= c.page_count - 1 THEN 1 ELSE 0 END) as read_ct,
                       r.cover_image_path
                FROM runs r
                LEFT JOIN run_items ri ON ri.run_id = r.id
                LEFT JOIN comics c    ON c.id = ri.comic_id AND c.deleted_at IS NULL
                LEFT JOIN reading_progress rp ON rp.comic_id = c.id
                GROUP BY r.id
                ORDER BY COALESCE(r.position, r.id * -1)
            """
            return rows(sql, map: { s in
                Run(id: colInt64(s, 0), title: colText(s, 1) ?? "", description: colText(s, 2) ?? "",
                    rating: colInt(s, 3) > 0 ? colInt(s, 3) : nil,
                    review: colText(s, 4), buyLink: colText(s, 5), createdAt: colText(s, 6) ?? "",
                    comicCount: colInt(s, 7), readCount: colInt(s, 8), coverImagePath: colText(s, 9))
            })
        }
    }

    @discardableResult
    func createRun(title: String, description: String) -> Int64 {
        queue.sync { run("INSERT INTO runs (title, description) VALUES (?,?)", args: [title, description]) }
    }

    func setRunCover(runId: Int64, imagePath: String) {
        queue.sync { _ = run("UPDATE runs SET cover_image_path = ? WHERE id = ?", args: [imagePath, runId]) }
    }

    func clearRunCover(runId: Int64) {
        queue.sync { _ = run("UPDATE runs SET cover_image_path = NULL WHERE id = ?", args: [runId]) }
    }

    func reorderRuns(orderedIds: [Int64]) {
        _ = queue.sync {
            inTransaction {
                runBatch("UPDATE runs SET position = ? WHERE id = ?",
                         rows: orderedIds.enumerated().map { [$0.offset, $0.element] })
            }
        }
    }

    func runId(withTitle title: String) -> Int64? {
        queue.sync {
            let id = scalarInt("SELECT id FROM runs WHERE title = ? LIMIT 1", args: [title])
            return id > 0 ? Int64(id) : nil
        }
    }

    func deleteRun(_ runId: Int64) {
        queue.sync { _ = run("DELETE FROM runs WHERE id=?", args: [runId]) }
    }

    func runItems(runId: Int64) -> [RunItem] {
        queue.sync {
            let sql = """
            SELECT ri.id, ri.position, COALESCE(ri.notes,''),
                   c.id, c.title, c.file_path, c.publisher, c.character, c.series,
                   c.issue_number, c.page_count, c.writer, c.penciller, c.year,
                   c.story_arc, c.language_iso, c.notes, c.added_at, c.deleted_at,
                   COALESCE(c.position, c.id), c.file_hash,
                   COALESCE(rp.current_page, 0), rp.last_read,
                   COALESCE(r.rating, 0), (f.comic_id IS NOT NULL), (rl.comic_id IS NOT NULL)
            FROM run_items ri
            JOIN comics c ON ri.comic_id = c.id AND c.deleted_at IS NULL
            LEFT JOIN reading_progress rp ON c.id = rp.comic_id
            LEFT JOIN ratings r           ON c.id = r.comic_id
            LEFT JOIN favorites f         ON c.id = f.comic_id
            LEFT JOIN reading_list rl     ON c.id = rl.comic_id
            WHERE ri.run_id = ? ORDER BY ri.position
            """
            return rows(sql, args: [runId]) { s -> RunItem in
                let comic = Comic(
                    id: colInt64(s, 3), title: colText(s, 4) ?? "", filePath: colText(s, 5) ?? "",
                    publisher: colText(s, 6) ?? "Unknown", character: colText(s, 7), series: colText(s, 8) ?? "General",
                    issueNumber: colText(s, 9), pageCount: colInt(s, 10), writer: colText(s, 11),
                    penciller: colText(s, 12), year: sqlite3_column_type(s, 13) != SQLITE_NULL ? colInt(s, 13) : nil,
                    storyArc: colText(s, 14), languageIso: colText(s, 15), notes: colText(s, 16),
                    addedAt: colText(s, 17) ?? "", deletedAt: colText(s, 18),
                    position: colInt(s, 19), fileHash: colText(s, 20),
                    progress: colInt(s, 21), lastRead: colText(s, 22),
                    rating: colInt(s, 23), isFavorite: colBool(s, 24), inReadingList: colBool(s, 25)
                )
                return RunItem(id: colInt64(s, 0), comic: comic,
                               position: colInt(s, 1), notes: colText(s, 2) ?? "")
            }
        }
    }

    func addToRun(runId: Int64, comicIds: [Int64]) {
        guard !comicIds.isEmpty else { return }
        queue.sync {
            let startPos = scalarInt("SELECT COALESCE(MAX(position), -1) + 1 FROM run_items WHERE run_id = ?",
                                     args: [runId])
            inTransaction {
                runBatch("INSERT OR IGNORE INTO run_items (run_id, comic_id, position) VALUES (?,?,?)",
                         rows: comicIds.enumerated().map { [runId, $0.element, Int64(startPos + $0.offset)] })
            }
        }
    }

    func removeFromRun(runId: Int64, comicIds: [Int64]) {
        guard !comicIds.isEmpty else { return }
        _ = queue.sync {
            inTransaction {
                runBatch("DELETE FROM run_items WHERE run_id = ? AND comic_id = ?",
                         rows: comicIds.map { [runId, $0] })
            }
        }
    }

    func reorderRun(runId: Int64, orderedIds: [Int64]) {
        _ = queue.sync {
            inTransaction {
                runBatch("UPDATE run_items SET position = ? WHERE id = ? AND run_id = ?",
                         rows: orderedIds.enumerated().map { [$0.offset, $0.element, runId] })
            }
        }
    }

    func allLists() -> [ComicList] {
        queue.sync {
            let sql = """
                SELECT l.id, l.title, COALESCE(l.description,''), COALESCE(l.rating,0), l.review, l.created_at,
                       COUNT(li.id) as total, l.cover_image_path
                FROM lists l
                LEFT JOIN list_items li ON li.list_id = l.id
                LEFT JOIN comics c     ON c.id = li.comic_id AND c.deleted_at IS NULL
                GROUP BY l.id
                ORDER BY COALESCE(l.position, l.id * -1)
            """
            return rows(sql, map: { s in
                ComicList(id: colInt64(s, 0), title: colText(s, 1) ?? "", description: colText(s, 2) ?? "",
                          rating: colInt(s, 3) > 0 ? colInt(s, 3) : nil,
                          review: colText(s, 4), createdAt: colText(s, 5) ?? "",
                          comicCount: colInt(s, 6), coverImagePath: colText(s, 7))
            })
        }
    }

    @discardableResult
    func createList(title: String, description: String) -> Int64 {
        queue.sync { run("INSERT INTO lists (title, description) VALUES (?,?)", args: [title, description]) }
    }

    func setListCover(listId: Int64, imagePath: String) {
        queue.sync { _ = run("UPDATE lists SET cover_image_path = ? WHERE id = ?", args: [imagePath, listId]) }
    }

    func clearListCover(listId: Int64) {
        queue.sync { _ = run("UPDATE lists SET cover_image_path = NULL WHERE id = ?", args: [listId]) }
    }

    func reorderLists(orderedIds: [Int64]) {
        _ = queue.sync {
            inTransaction {
                runBatch("UPDATE lists SET position = ? WHERE id = ?",
                         rows: orderedIds.enumerated().map { [$0.offset, $0.element] })
            }
        }
    }

    func listId(withTitle title: String) -> Int64? {
        queue.sync {
            let id = scalarInt("SELECT id FROM lists WHERE title = ? LIMIT 1", args: [title])
            return id > 0 ? Int64(id) : nil
        }
    }

    func deleteList(_ listId: Int64) {
        queue.sync { _ = run("DELETE FROM lists WHERE id=?", args: [listId]) }
    }

    func listItems(listId: Int64) -> [ListItem] {
        queue.sync {
            let sql = """
            SELECT li.id, li.position, COALESCE(li.notes,''),
                   c.id, c.title, c.file_path, c.publisher, c.character, c.series,
                   c.issue_number, c.page_count, c.writer, c.penciller, c.year,
                   c.story_arc, c.language_iso, c.notes, c.added_at, c.deleted_at,
                   COALESCE(c.position, c.id), c.file_hash,
                   COALESCE(rp.current_page, 0), rp.last_read,
                   COALESCE(r.rating, 0), (f.comic_id IS NOT NULL), (rl.comic_id IS NOT NULL)
            FROM list_items li
            JOIN comics c ON li.comic_id = c.id AND c.deleted_at IS NULL
            LEFT JOIN reading_progress rp ON c.id = rp.comic_id
            LEFT JOIN ratings r           ON c.id = r.comic_id
            LEFT JOIN favorites f         ON c.id = f.comic_id
            LEFT JOIN reading_list rl     ON c.id = rl.comic_id
            WHERE li.list_id = ? ORDER BY li.position
            """
            return rows(sql, args: [listId]) { s -> ListItem in
                let comic = Comic(
                    id: colInt64(s, 3), title: colText(s, 4) ?? "", filePath: colText(s, 5) ?? "",
                    publisher: colText(s, 6) ?? "Unknown", character: colText(s, 7), series: colText(s, 8) ?? "General",
                    issueNumber: colText(s, 9), pageCount: colInt(s, 10), writer: colText(s, 11),
                    penciller: colText(s, 12), year: sqlite3_column_type(s, 13) != SQLITE_NULL ? colInt(s, 13) : nil,
                    storyArc: colText(s, 14), languageIso: colText(s, 15), notes: colText(s, 16),
                    addedAt: colText(s, 17) ?? "", deletedAt: colText(s, 18),
                    position: colInt(s, 19), fileHash: colText(s, 20),
                    progress: colInt(s, 21), lastRead: colText(s, 22),
                    rating: colInt(s, 23), isFavorite: colBool(s, 24), inReadingList: colBool(s, 25)
                )
                return ListItem(id: colInt64(s, 0), comic: comic,
                                 position: colInt(s, 1), notes: colText(s, 2) ?? "")
            }
        }
    }

    func addToList(listId: Int64, comicIds: [Int64]) {
        guard !comicIds.isEmpty else { return }
        queue.sync {
            let startPos = scalarInt("SELECT COALESCE(MAX(position), -1) + 1 FROM list_items WHERE list_id = ?",
                                     args: [listId])
            inTransaction {
                runBatch("INSERT OR IGNORE INTO list_items (list_id, comic_id, position) VALUES (?,?,?)",
                         rows: comicIds.enumerated().map { [listId, $0.element, Int64(startPos + $0.offset)] })
            }
        }
    }

    func removeFromList(listId: Int64, comicIds: [Int64]) {
        guard !comicIds.isEmpty else { return }
        _ = queue.sync {
            inTransaction {
                runBatch("DELETE FROM list_items WHERE list_id = ? AND comic_id = ?",
                         rows: comicIds.map { [listId, $0] })
            }
        }
    }

    func reorderList(listId: Int64, orderedIds: [Int64]) {
        _ = queue.sync {
            inTransaction {
                runBatch("UPDATE list_items SET position = ? WHERE id = ? AND list_id = ?",
                         rows: orderedIds.enumerated().map { [$0.offset, $0.element, listId] })
            }
        }
    }

    func allTierLists() -> [TierList] {
        queue.sync {
            let sql = """
                SELECT tl.id, tl.title, COALESCE(tl.description,''), tl.created_at, COUNT(tli.id) as total
                FROM tier_lists tl
                LEFT JOIN tier_list_items tli ON tli.tier_list_id = tl.id
                GROUP BY tl.id
                ORDER BY COALESCE(tl.position, tl.id * -1)
            """
            return rows(sql, map: { s in
                TierList(id: colInt64(s, 0), title: colText(s, 1) ?? "", description: colText(s, 2) ?? "",
                          createdAt: colText(s, 3) ?? "", comicCount: colInt(s, 4))
            })
        }
    }

    @discardableResult
    func createTierList(title: String, description: String) -> Int64 {
        queue.sync { run("INSERT INTO tier_lists (title, description) VALUES (?,?)", args: [title, description]) }
    }

    func reorderTierLists(orderedIds: [Int64]) {
        _ = queue.sync {
            inTransaction {
                runBatch("UPDATE tier_lists SET position = ? WHERE id = ?",
                         rows: orderedIds.enumerated().map { [$0.offset, $0.element] })
            }
        }
    }

    func tierListId(withTitle title: String) -> Int64? {
        queue.sync {
            let id = scalarInt("SELECT id FROM tier_lists WHERE title = ? LIMIT 1", args: [title])
            return id > 0 ? Int64(id) : nil
        }
    }

    func deleteTierList(_ tierListId: Int64) {
        queue.sync { _ = run("DELETE FROM tier_lists WHERE id=?", args: [tierListId]) }
    }

    func tierListItems(tierListId: Int64) -> [TierListItem] {
        queue.sync {
            let sql = """
            SELECT tli.id, tli.tier, tli.position,
                   c.id, c.title, c.file_path, c.publisher, c.character, c.series,
                   c.issue_number, c.page_count, c.writer, c.penciller, c.year,
                   c.story_arc, c.language_iso, c.notes, c.added_at, c.deleted_at,
                   COALESCE(c.position, c.id), c.file_hash,
                   COALESCE(rp.current_page, 0), rp.last_read,
                   COALESCE(r.rating, 0), (f.comic_id IS NOT NULL), (rl.comic_id IS NOT NULL)
            FROM tier_list_items tli
            JOIN comics c ON tli.comic_id = c.id AND c.deleted_at IS NULL
            LEFT JOIN reading_progress rp ON c.id = rp.comic_id
            LEFT JOIN ratings r           ON c.id = r.comic_id
            LEFT JOIN favorites f         ON c.id = f.comic_id
            LEFT JOIN reading_list rl     ON c.id = rl.comic_id
            WHERE tli.tier_list_id = ? ORDER BY tli.position
            """
            return rows(sql, args: [tierListId]) { s -> TierListItem in
                let comic = Comic(
                    id: colInt64(s, 3), title: colText(s, 4) ?? "", filePath: colText(s, 5) ?? "",
                    publisher: colText(s, 6) ?? "Unknown", character: colText(s, 7), series: colText(s, 8) ?? "General",
                    issueNumber: colText(s, 9), pageCount: colInt(s, 10), writer: colText(s, 11),
                    penciller: colText(s, 12), year: sqlite3_column_type(s, 13) != SQLITE_NULL ? colInt(s, 13) : nil,
                    storyArc: colText(s, 14), languageIso: colText(s, 15), notes: colText(s, 16),
                    addedAt: colText(s, 17) ?? "", deletedAt: colText(s, 18),
                    position: colInt(s, 19), fileHash: colText(s, 20),
                    progress: colInt(s, 21), lastRead: colText(s, 22),
                    rating: colInt(s, 23), isFavorite: colBool(s, 24), inReadingList: colBool(s, 25)
                )
                return TierListItem(id: colInt64(s, 0), comic: comic,
                                     tier: colText(s, 1) ?? "B", position: colInt(s, 2))
            }
        }
    }

    func addToTierList(tierListId: Int64, comicIds: [Int64], tier: String = "B") {
        guard !comicIds.isEmpty else { return }
        queue.sync {
            let startPos = scalarInt("SELECT COALESCE(MAX(position), -1) + 1 FROM tier_list_items WHERE tier_list_id = ? AND tier = ?",
                                     args: [tierListId, tier])
            inTransaction {
                runBatch("INSERT OR IGNORE INTO tier_list_items (tier_list_id, comic_id, tier, position) VALUES (?,?,?,?)",
                         rows: comicIds.enumerated().map { [tierListId, $0.element, tier, Int64(startPos + $0.offset)] })
            }
        }
    }

    func removeFromTierList(tierListId: Int64, comicIds: [Int64]) {
        guard !comicIds.isEmpty else { return }
        _ = queue.sync {
            inTransaction {
                runBatch("DELETE FROM tier_list_items WHERE tier_list_id = ? AND comic_id = ?",
                         rows: comicIds.map { [tierListId, $0] })
            }
        }
    }

    /// Moves an item to a (possibly different) tier, appended at the end of that tier's own
    /// ordering -- fine-grained drag-to-a-specific-slot within a tier isn't supported, only
    /// which tier an item belongs to and its append order within it.
    func setTierListItemTier(itemId: Int64, tierListId: Int64, tier: String) {
        queue.sync {
            let startPos = scalarInt("SELECT COALESCE(MAX(position), -1) + 1 FROM tier_list_items WHERE tier_list_id = ? AND tier = ?",
                                     args: [tierListId, tier])
            _ = run("UPDATE tier_list_items SET tier = ?, position = ? WHERE id = ?",
                    args: [tier, startPos, itemId])
        }
    }

    func loadStats() -> LibraryStats {
        queue.sync {
            let total     = scalarInt("SELECT COUNT(*) FROM comics WHERE deleted_at IS NULL")
            let pagesRead = scalarInt("SELECT COALESCE(SUM(rp.current_page),0) FROM reading_progress rp JOIN comics c ON rp.comic_id = c.id WHERE c.deleted_at IS NULL")
            let favorites = scalarInt("SELECT COUNT(*) FROM favorites f JOIN comics c ON f.comic_id = c.id WHERE c.deleted_at IS NULL")
            let inProg    = scalarInt("""
                SELECT COUNT(*) FROM comics c JOIN reading_progress rp ON c.id = rp.comic_id
                WHERE rp.current_page > 0 AND (c.page_count = 0 OR rp.current_page < c.page_count - 2) AND c.deleted_at IS NULL
            """)
            let finished  = scalarInt("""
                SELECT COUNT(*) FROM comics c JOIN reading_progress rp ON c.id = rp.comic_id
                WHERE c.page_count > 1 AND rp.current_page >= c.page_count - 2 AND c.deleted_at IS NULL
            """)
            let runsCount = scalarInt("SELECT COUNT(*) FROM runs")

            let streakDates = rows("SELECT DISTINCT date(last_read) FROM reading_progress ORDER BY date(last_read) DESC") {
                colText($0, 0) ?? ""
            }
            let streak = computeStreak(dates: streakDates)

            let activityMap = readingActivityMap(days: 365)

            let pubRows = rows("""
                SELECT publisher, COUNT(*) FROM comics WHERE deleted_at IS NULL
                GROUP BY publisher ORDER BY COUNT(*) DESC
            """) { PublisherStat(publisher: colText($0, 0) ?? "", count: colInt($0, 1)) }

            let seriesRows = rows("""
                SELECT series, publisher, COUNT(*) FROM comics WHERE deleted_at IS NULL
                GROUP BY publisher, series ORDER BY COUNT(*) DESC LIMIT 5
            """) { SeriesStat(series: colText($0, 0) ?? "", publisher: colText($0, 1) ?? "", count: colInt($0, 2)) }

            let recent = rows("""
                \(comicSelect)
                WHERE c.deleted_at IS NULL AND rp.comic_id IS NOT NULL
                ORDER BY rp.last_read DESC LIMIT 8
            """, map: comicRow)

            let growth = monthlyCollectionGrowth(months: 6)

            return LibraryStats(totalComics: total, pagesRead: pagesRead, favorites: favorites,
                                inProgress: inProg, finished: finished, unread: max(0, total - inProg - finished),
                                runsCount: runsCount, readingStreak: streak, activityMap: activityMap,
                                publisherBreakdown: pubRows, topSeries: seriesRows, recentlyRead: recent,
                                collectionGrowth: growth)
        }
    }

    private func monthlyCollectionGrowth(months: Int) -> [GrowthPoint] {
        let raw = rows("""
            SELECT strftime('%Y-%m', added_at) as ym, COUNT(*)
            FROM comics
            WHERE deleted_at IS NULL AND added_at >= date('now', '-\(months) months', 'start of month')
            GROUP BY ym ORDER BY ym
        """) { (colText($0, 0) ?? "", colInt($0, 1)) }
        let counts = Dictionary(uniqueKeysWithValues: raw)

        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM"; fmt.locale = Locale(identifier: "en_US_POSIX")
        let labelFmt = DateFormatter(); labelFmt.dateFormat = "MMM"; labelFmt.locale = Locale(identifier: "en_US_POSIX")

        var points: [GrowthPoint] = []
        for offset in stride(from: months - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .month, value: -offset, to: Date()) else { continue }
            let key = fmt.string(from: date)
            points.append(GrowthPoint(month: key, label: labelFmt.string(from: date), count: counts[key] ?? 0))
        }
        return points
    }

    private static let yyyyMMddFormatter: DateFormatter = {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()

    private func readingActivityMap(days: Int) -> [String: Int] {
        var map: [String: Int] = [:]
        let rows = self.rows("""
            SELECT date(last_read) as d, COUNT(*) FROM reading_progress
            WHERE last_read >= date('now', '-\(days) days')
            GROUP BY d
        """) { (colText($0, 0) ?? "", colInt($0, 1)) }
        for (d, c) in rows { map[d] = c }
        return map
    }

    private func computeStreak(dates: [String]) -> Int {
        guard !dates.isEmpty else { return 0 }
        let fmt = Self.yyyyMMddFormatter
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return 0 }
        var streak = 0; var expected: Date?
        for str in dates {
            guard let d = fmt.date(from: str) else { continue }
            let day = cal.startOfDay(for: d)
            if expected == nil {
                guard day == today || day == yesterday else { break }
                streak = 1; expected = cal.date(byAdding: .day, value: -1, to: day)
            } else if day == expected {
                streak += 1; expected = cal.date(byAdding: .day, value: -1, to: day)
            } else { break }
        }
        return streak
    }

    func clearAll() {
        queue.sync {
            // Unlike every other multi-statement mutator in this file, these deletes ran as
            // separate auto-commit transactions -- a force-quit/crash mid-sequence (this is a
            // user-triggered destructive "reset library" action) could leave some tables wiped
            // and others not, an inconsistent state with no recovery path.
            exec("BEGIN")
            exec("DELETE FROM reading_history")
            exec("DELETE FROM reading_progress")
            exec("DELETE FROM reading_goals")
            exec("DELETE FROM bookmarks")
            exec("DELETE FROM ratings")
            exec("DELETE FROM favorites")
            exec("DELETE FROM reading_list")
            exec("DELETE FROM comic_tags")
            exec("DELETE FROM series_covers")
            exec("DELETE FROM run_items")
            exec("DELETE FROM runs")
            exec("DELETE FROM tags")
            // "Clear All" is a full factory reset, not just a comics wipe -- these have no
            // foreign key to comics (keyed by series/publisher name, or independent user-created
            // collections) so they'd otherwise silently survive a reset untouched.
            exec("DELETE FROM list_items")
            exec("DELETE FROM lists")
            exec("DELETE FROM tier_list_items")
            exec("DELETE FROM tier_lists")
            exec("DELETE FROM diary_entries")
            exec("DELETE FROM series_links")
            exec("DELETE FROM reading_order_overrides")
            exec("DELETE FROM metadata_conflicts")
            exec("DELETE FROM series_reader_prefs")
            exec("DELETE FROM character_covers")
            exec("DELETE FROM series_order")
            exec("DELETE FROM character_order")
            exec("DELETE FROM publisher_order")
            exec("DELETE FROM comics")
            exec("COMMIT")
        }
    }

    func batchUpdateFolderMeta(_ items: [(id: Int64, pub: String?, char: String?, ser: String?, title: String, issueNumber: String?, year: Int?)]) {
        queue.sync {
            // Captured before the update -- a folder rename that changes a comic's (publisher,
            // series) would otherwise silently orphan any series_links row still pointing at the
            // old name (it no longer matches anything in `comics`), breaking whatever
            // volume-aware reading-order chaining that link was providing. Only rows this update
            // will actually touch (meta_edited=0) count, matching the same guard the update
            // itself uses below.
            var renameMappings: Set<[String]> = []
            let idsWithNewSeries = items.compactMap { $0.ser != nil ? $0.id : nil }
            if !idsWithNewSeries.isEmpty {
                let placeholders = idsWithNewSeries.map { _ in "?" }.joined(separator: ",")
                let current = Dictionary(uniqueKeysWithValues: rows(
                    "SELECT id, publisher, series FROM comics WHERE id IN (\(placeholders)) AND meta_edited = 0",
                    args: idsWithNewSeries.map { $0 as Any? }
                ) { s in (colInt64(s, 0), (pub: colText(s, 1) ?? "", ser: colText(s, 2) ?? "")) })
                for item in items {
                    guard let newSer = item.ser, let old = current[item.id] else { continue }
                    let newPub = item.pub ?? old.pub
                    guard old.ser != newSer || old.pub != newPub else { continue }
                    renameMappings.insert([old.pub, old.ser, newPub, newSer])
                }
            }

            exec("BEGIN")
            for item in items {
                if let pub = item.pub {
                    _ = run("UPDATE comics SET publisher=? WHERE id=? AND meta_edited=0", args: [pub, item.id])
                }
                if let char = item.char {
                    _ = run("UPDATE comics SET character=? WHERE id=? AND meta_edited=0", args: [char, item.id])
                } else {
                    _ = run("UPDATE comics SET character=NULL WHERE id=? AND meta_edited=0 AND (character LIKE '%,%' OR character LIKE '%[%' OR LENGTH(COALESCE(character,''))>60)",
                            args: [item.id])
                }
                if let ser = item.ser {
                    _ = run("UPDATE comics SET series=? WHERE id=? AND meta_edited=0", args: [ser, item.id])
                }
                _ = run("UPDATE comics SET title=? WHERE id=? AND meta_edited=0", args: [item.title, item.id])

                if let num = item.issueNumber {
                    _ = run("""
                        UPDATE comics SET issue_number=? WHERE id=? AND meta_edited=0
                        AND (issue_number IS NULL OR issue_number != ?)
                        """, args: [num, item.id, num])
                }
                if let year = item.year {
                    // Only ever fills a genuinely empty year -- a real ComicInfo.xml <Year> tag
                    // (on the rare file that has one) is always a better source than a filename
                    // guess and must never be overwritten by it.
                    _ = run("UPDATE comics SET year=? WHERE id=? AND meta_edited=0 AND year IS NULL", args: [year, item.id])
                }
            }
            exec("COMMIT")

            // Wrapped in its own transaction: a crash between the parent-side and child-side
            // update for one mapping, or between mappings when several series are renamed in the
            // same batch, would otherwise leave series_links partially resynced against comics
            // rows that have already committed their new names.
            if !renameMappings.isEmpty {
                exec("BEGIN")
                for mapping in renameMappings {
                    let (oldPub, oldSer, newPub, newSer) = (mapping[0], mapping[1], mapping[2], mapping[3])
                    _ = run("UPDATE series_links SET parent_publisher = ?, parent_series = ? WHERE parent_publisher = ? AND parent_series = ?",
                            args: [newPub, newSer, oldPub, oldSer])
                    _ = run("UPDATE series_links SET child_publisher = ?, child_series = ? WHERE child_publisher = ? AND child_series = ?",
                            args: [newPub, newSer, oldPub, oldSer])
                }
                exec("COMMIT")
            }

            exec("""
                UPDATE comics SET position =
                    is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
                    + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
            """)
        }
        positionSpecialsChronologically()
        recomputeReadingOrder()
    }

    func updateFileHash(id: Int64, hash: String) {
        queue.sync {
            _ = run("UPDATE comics SET file_hash = ? WHERE id = ?", args: [hash, id])
        }
    }

    func updateFilePath(forHash hash: String, newPath: String) {
        queue.sync {
            _ = run("UPDATE comics SET file_path = ? WHERE file_hash = ? AND deleted_at IS NULL",
                    args: [newPath, hash])
        }
    }

    func path(forHash hash: String) -> String? {
        queue.sync {
            scalarText("SELECT file_path FROM comics WHERE file_hash = ? AND deleted_at IS NULL", args: [hash])
        }
    }

    func idForHash(_ hash: String) -> Int64? {
        queue.sync {
            rows("SELECT id FROM comics WHERE file_hash = ? AND deleted_at IS NULL", args: [hash], map: { colInt64($0, 0) }).first
        }
    }

    func updateFilePath(id: Int64, newPath: String) {
        queue.sync {
            _ = run("UPDATE comics SET file_path = ? WHERE id = ?", args: [newPath, id])
        }
    }

    /// Same query as `allComicPaths()` under a name that reads better at its "which of these
    /// are still on disk" call sites; kept as a single query so the two never drift apart.
    func stalePaths() -> [(id: Int64, path: String)] { allComicPaths() }

    func allTags() -> [(tag: Tag, count: Int)] {
        queue.sync {
            rows("""
                SELECT t.id, t.name, t.category, COUNT(ct.comic_id) as cnt
                FROM tags t JOIN comic_tags ct ON t.id = ct.tag_id
                JOIN comics c ON ct.comic_id = c.id
                WHERE c.deleted_at IS NULL
                GROUP BY t.id ORDER BY cnt DESC, t.name
            """) { (Tag(id: colInt64($0, 0), name: colText($0, 1) ?? "", category: colText($0, 2)), colInt($0, 3)) }
        }
    }

    /// Renames a tag across the whole library. `tags.name` is UNIQUE, so if `newName` already
    /// belongs to a different tag, this merges into it instead of erroring: every comic tagged
    /// with either ends up tagged with just the target, and the old tag row is removed.
    func renameTag(id: Int64, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.sync {
            let existingId = scalarInt("SELECT id FROM tags WHERE name = ? AND id != ?", args: [trimmed, id])
            if existingId > 0 {
                inTransaction {
                    // Repoint every comic_tags row from the old tag to the target tag; a row
                    // that would collide with the target's own PRIMARY KEY (comic_id, tag_id) --
                    // i.e. a comic already wearing both tags -- is left alone here and cleaned
                    // up by the cascade below instead of erroring the whole rename.
                    guard run("UPDATE OR IGNORE comic_tags SET tag_id = ? WHERE tag_id = ?",
                              args: [Int64(existingId), id]) != -1 else { return false }
                    guard run("DELETE FROM tags WHERE id = ?", args: [id]) != -1 else { return false }
                    return true
                }
            } else {
                _ = run("UPDATE tags SET name = ? WHERE id = ?", args: [trimmed, id])
            }
        }
    }

    /// Removes a tag from the entire library (every comic that had it), not just one comic --
    /// `comic_tags.tag_id` cascades, so this is the one statement that needs to run.
    func deleteTagGlobally(id: Int64) {
        queue.sync { _ = run("DELETE FROM tags WHERE id = ?", args: [id]) }
    }

    func setTagCategory(id: Int64, category: TagCategory) {
        queue.sync { _ = run("UPDATE tags SET category = ? WHERE id = ?", args: [category.rawValue, id]) }
    }

    func setRunRating(_ runId: Int64, rating: Int, review: String?) {
        queue.sync {
            _ = run("UPDATE runs SET rating = ?, review = ? WHERE id = ?",
                    args: [rating > 0 ? rating : nil, review, runId])
        }
    }

    func setRunItemNotes(_ itemId: Int64, notes: String) {
        queue.sync {
            _ = run("UPDATE run_items SET notes = ? WHERE id = ?",
                    args: [notes.isEmpty ? nil : notes, itemId])
        }
    }

    func setListRating(_ listId: Int64, rating: Int, review: String?) {
        queue.sync {
            _ = run("UPDATE lists SET rating = ?, review = ? WHERE id = ?",
                    args: [rating > 0 ? rating : nil, review, listId])
        }
    }

    func setListItemNotes(_ itemId: Int64, notes: String) {
        queue.sync {
            _ = run("UPDATE list_items SET notes = ? WHERE id = ?",
                    args: [notes.isEmpty ? nil : notes, itemId])
        }
    }

    struct CharacterGroup: Identifiable {
        let id: String
        let groupName: String
        let character: String?
        let publisher: String
        let count: Int
        let coverId: Int64
        let coverImagePath: String?
        let started: Int
        let finished: Int
    }

    struct SeriesGroup: Identifiable {
        let id: String
        let series: String
        let publisher: String
        let count: Int
        let coverId: Int64
        let started: Int
        let finished: Int
        var coverImagePath: String? = nil
    }

    func characterGroups(publisher: String? = nil, search: String? = nil) -> [CharacterGroup] {
        queue.sync {
            var conds = ["c.deleted_at IS NULL"]
            var args: [Any?] = []
            if let pub = publisher, pub != "All" { conds.append("c.publisher = ?"); args.append(pub) }
            if let q = search, !q.isEmpty {
                conds.append("(c.series LIKE ? ESCAPE '\\' OR (c.character NOT LIKE '%,%' AND c.character NOT LIKE '%[%' AND LENGTH(COALESCE(c.character,'')) <= 60 AND c.character LIKE ? ESCAPE '\\'))")
                let p = "%\(Self.likeEscaped(q))%"
                args += [p, p]
            }

            let cleanChar = """
                CASE
                  WHEN c.character IS NULL
                    OR c.character LIKE '%,%'
                    OR c.character LIKE '%[%'
                    OR c.character LIKE '%(%'
                    OR LENGTH(c.character) > 60
                  THEN c.series
                  ELSE c.character
                END
            """
            let sql = """
                SELECT \(cleanChar) as group_name,
                       c.character, c.publisher,
                       COUNT(*) as cnt,
                       COALESCE(sc.comic_id, MIN(c.id)) as cover_id,
                       SUM(CASE WHEN rp.current_page > 0 THEN 1 ELSE 0 END) as started,
                       SUM(CASE WHEN c.page_count > 1 AND rp.current_page >= c.page_count - 1 THEN 1 ELSE 0 END) as finished,
                       cc.image_path
                FROM comics c
                LEFT JOIN reading_progress rp ON c.id = rp.comic_id
                LEFT JOIN series_covers sc ON sc.series = c.series AND sc.publisher = c.publisher
                LEFT JOIN character_covers cc ON cc.group_name = (\(cleanChar)) AND cc.publisher = c.publisher
                LEFT JOIN character_order co ON co.group_name = (\(cleanChar)) AND co.publisher = c.publisher
                WHERE \(conds.joined(separator: " AND "))
                GROUP BY c.publisher, \(cleanChar)
                ORDER BY c.publisher, COALESCE(co.position, 999999), group_name
            """
            return rows(sql, args: args) { s in
                let gn  = colText(s, 0) ?? ""
                let pub = colText(s, 2) ?? ""
                return CharacterGroup(
                    id: "\(pub):\(gn)",
                    groupName: gn,
                    character: colText(s, 1),
                    publisher: pub,
                    count: colInt(s, 3),
                    coverId: colInt64(s, 4),
                    coverImagePath: colText(s, 7),
                    started: colInt(s, 5),
                    finished: colInt(s, 6)
                )
            }
        }
    }

    func seriesGroups(groupName: String, publisher: String? = nil) -> [SeriesGroup] {
        queue.sync {

            let cleanChar = """
                CASE
                  WHEN c.character IS NULL
                    OR c.character LIKE '%,%'
                    OR c.character LIKE '%[%'
                    OR c.character LIKE '%(%'
                    OR LENGTH(c.character) > 60
                  THEN c.series
                  ELSE c.character
                END
            """
            var conds = ["c.deleted_at IS NULL", "(\(cleanChar)) = ?"]
            var args: [Any?] = [groupName]
            if let pub = publisher, pub != "All" { conds.append("c.publisher = ?"); args.append(pub) }
            let sql = """
                SELECT c.series, c.publisher, COUNT(*) as cnt,
                       COALESCE(sc.comic_id, MIN(c.id)) as cover_id,
                       SUM(CASE WHEN rp.current_page > 0 THEN 1 ELSE 0 END) as started,
                       SUM(CASE WHEN c.page_count > 1 AND rp.current_page >= c.page_count - 1 THEN 1 ELSE 0 END) as finished,
                       sc.image_path
                FROM comics c
                LEFT JOIN reading_progress rp ON c.id = rp.comic_id
                LEFT JOIN series_covers sc ON sc.series = c.series AND sc.publisher = c.publisher
                WHERE \(conds.joined(separator: " AND "))
                GROUP BY c.series
                ORDER BY COALESCE(
                    (SELECT so.position FROM series_order so
                     WHERE so.group_name = ? AND so.publisher = ? AND so.series = c.series),
                    9999
                ), c.series
            """
            args.append(groupName)
            args.append(publisher ?? "")
            return rows(sql, args: args) { s in
                let ser = colText(s, 0) ?? ""
                let pub = colText(s, 1) ?? ""
                return SeriesGroup(id: "\(pub):\(ser)", series: ser, publisher: pub,
                                   count: colInt(s, 2), coverId: colInt64(s, 3),
                                   started: colInt(s, 4), finished: colInt(s, 5),
                                   coverImagePath: colText(s, 6))
            }
        }
    }

    func setSeriesCover(series: String, publisher: String, comicId: Int64) {
        queue.sync {
            _ = run("INSERT OR REPLACE INTO series_covers (series, publisher, comic_id) VALUES (?, ?, ?)",
                    args: [series, publisher, comicId])
        }
    }

    func clearSeriesCover(series: String, publisher: String) {
        queue.sync {
            _ = run("DELETE FROM series_covers WHERE series = ? AND publisher = ?",
                    args: [series, publisher])
        }
    }

    func setSeriesCoverImage(series: String, publisher: String, imagePath: String) {
        queue.sync {
            _ = run("""
            INSERT INTO series_covers (series, publisher, comic_id, image_path) VALUES (?, ?, NULL, ?)
            ON CONFLICT(series, publisher) DO UPDATE SET image_path = excluded.image_path, comic_id = NULL
            """, args: [series, publisher, imagePath])
        }
    }

    func currentSeriesCover(series: String, publisher: String) -> Int64? {
        queue.sync {
            var raw: OpaquePointer?
            let sql = "SELECT comic_id FROM series_covers WHERE series = ? AND publisher = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindArgs(stmt, args: [series, publisher])
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    struct SeriesReaderPrefs {
        let fitMode:      String
        let rtl:          Bool
        let doubleSpread: Bool
        let scrollMode:   Bool
    }

    func setSeriesReaderPrefs(series: String, publisher: String, fitMode: String, rtl: Bool, doubleSpread: Bool, scrollMode: Bool) {
        queue.sync {
            _ = run("""
            INSERT OR REPLACE INTO series_reader_prefs (series, publisher, fit_mode, rtl, double_spread, scroll_mode)
            VALUES (?, ?, ?, ?, ?, ?)
            """, args: [series, publisher, fitMode, rtl ? 1 : 0, doubleSpread ? 1 : 0, scrollMode ? 1 : 0])
        }
    }

    func seriesReaderPrefs(series: String, publisher: String) -> SeriesReaderPrefs? {
        queue.sync {
            var raw: OpaquePointer?
            let sql = "SELECT fit_mode, rtl, double_spread, scroll_mode FROM series_reader_prefs WHERE series = ? AND publisher = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindArgs(stmt, args: [series, publisher])
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let fitMode = String(cString: sqlite3_column_text(stmt, 0))
            return SeriesReaderPrefs(fitMode: fitMode,
                                      rtl:          sqlite3_column_int(stmt, 1) != 0,
                                      doubleSpread: sqlite3_column_int(stmt, 2) != 0,
                                      scrollMode:   sqlite3_column_int(stmt, 3) != 0)
        }
    }

    func setCharacterGroupCover(groupName: String, publisher: String, imagePath: String) {
        queue.sync {
            _ = run("INSERT OR REPLACE INTO character_covers (group_name, publisher, image_path) VALUES (?,?,?)",
                    args: [groupName, publisher, imagePath])
        }
    }

    func clearCharacterGroupCover(groupName: String, publisher: String) {
        queue.sync {
            _ = run("DELETE FROM character_covers WHERE group_name = ? AND publisher = ?",
                    args: [groupName, publisher])
        }
    }

    func reorderSeriesGroups(groupName: String, publisher: String, orderedSeries: [String]) {
        guard !orderedSeries.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for (idx, series) in orderedSeries.enumerated() {
                _ = run("INSERT OR REPLACE INTO series_order (group_name, publisher, series, position) VALUES (?,?,?,?)",
                        args: [groupName, publisher, series, idx])
            }
            exec("COMMIT")
        }
    }

    func reorderCharacterGroups(publisher: String, orderedGroupNames: [String]) {
        guard !orderedGroupNames.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for (idx, groupName) in orderedGroupNames.enumerated() {
                _ = run("INSERT OR REPLACE INTO character_order (group_name, publisher, position) VALUES (?,?,?)",
                        args: [groupName, publisher, idx])
            }
            exec("COMMIT")
        }
    }

    func bookmarks(comicId: Int64) -> [Bookmark] {
        queue.sync {
            rows("SELECT id, comic_id, page, label, created_at, is_favorite FROM bookmarks WHERE comic_id = ? ORDER BY page",
                 args: [comicId]) { s in
                Bookmark(id: colInt64(s, 0), comicId: colInt64(s, 1),
                         page: colInt(s, 2), label: colText(s, 3) ?? "",
                         createdAt: colText(s, 4) ?? "", isFavorite: colInt(s, 5) != 0)
            }
        }
    }

    /// Every bookmark flagged as a favorite moment, across the whole library, newest first --
    /// backing the standalone "Favorite Moments" browsing screen. Same two-step shape as
    /// `diaryEntries`: fetch the child rows, then batch-resolve their comics via one IN query.
    func favoriteMoments() -> [FavoriteMoment] {
        queue.sync {
            let raw: [Bookmark] = rows("""
                SELECT id, comic_id, page, label, created_at, is_favorite
                FROM bookmarks WHERE is_favorite = 1
                ORDER BY created_at DESC
                """) { s in
                Bookmark(id: colInt64(s, 0), comicId: colInt64(s, 1),
                          page: colInt(s, 2), label: colText(s, 3) ?? "",
                          createdAt: colText(s, 4) ?? "", isFavorite: colInt(s, 5) != 0)
            }
            guard !raw.isEmpty else { return [] }

            let comicIds = Array(Set(raw.map(\.comicId)))
            let placeholders = comicIds.map { _ in "?" }.joined(separator: ",")
            let comicsById: [Int64: Comic] = Dictionary(uniqueKeysWithValues:
                rows("\(comicSelect) WHERE c.id IN (\(placeholders)) AND c.deleted_at IS NULL",
                     args: comicIds, map: comicRow).map { ($0.id, $0) }
            )
            return raw.compactMap { bookmark in
                guard let comic = comicsById[bookmark.comicId] else { return nil }
                return FavoriteMoment(bookmark: bookmark, comic: comic)
            }
        }
    }

    @discardableResult
    func toggleBookmark(comicId: Int64, page: Int) -> Bool {
        queue.sync {
            let exists = scalarInt("SELECT COUNT(*) FROM bookmarks WHERE comic_id=? AND page=?",
                                   args: [comicId, page]) > 0
            if exists {
                _ = run("DELETE FROM bookmarks WHERE comic_id=? AND page=?", args: [comicId, page])
                return false
            } else {
                _ = run("INSERT OR REPLACE INTO bookmarks (comic_id, page) VALUES (?,?)", args: [comicId, page])
                return true
            }
        }
    }

    func setBookmarkLabel(comicId: Int64, page: Int, label: String) {
        queue.async {
            _ = self.run("UPDATE bookmarks SET label=? WHERE comic_id=? AND page=?",
                         args: [label, comicId, page])
        }
    }

    /// Favoriting a page that isn't already bookmarked creates the bookmark -- a favorite moment
    /// IS a bookmark, just one flagged as worth revisiting on its own.
    func setBookmarkFavorite(comicId: Int64, page: Int, isFavorite: Bool) {
        queue.sync {
            _ = run("INSERT OR IGNORE INTO bookmarks (comic_id, page) VALUES (?,?)", args: [comicId, page])
            _ = run("UPDATE bookmarks SET is_favorite=? WHERE comic_id=? AND page=?",
                    args: [isFavorite ? 1 : 0, comicId, page])
        }
    }

    func isBookmarked(comicId: Int64, page: Int) -> Bool {
        queue.sync {
            scalarInt("SELECT COUNT(*) FROM bookmarks WHERE comic_id=? AND page=?",
                      args: [comicId, page]) > 0
        }
    }

    func logReadingSession(comicId: Int64, pageStart: Int, pageEnd: Int) {
        guard pageEnd > pageStart else { return }
        queue.async {
            _ = self.run("INSERT INTO reading_history (comic_id, page_start, page_end) VALUES (?,?,?)",
                         args: [comicId, pageStart, pageEnd])
        }
    }

    func readingHistory(limit: Int = 100) -> [HistoryEntry] {
        queue.sync {
            let sql = """
                SELECT h.id, h.comic_id, c.title, c.publisher, c.series,
                       h.page_start, h.page_end, h.read_at
                FROM reading_history h
                JOIN comics c ON c.id = h.comic_id
                ORDER BY h.read_at DESC
                LIMIT \(limit)
            """
            return rows(sql) { s in
                HistoryEntry(
                    id: colInt64(s, 0), comicId: colInt64(s, 1),
                    title: colText(s, 2) ?? "", publisher: colText(s, 3) ?? "",
                    series: colText(s, 4) ?? "",
                    pageStart: colInt(s, 5), pageEnd: colInt(s, 6),
                    readAt: colText(s, 7) ?? ""
                )
            }
        }
    }

    func issuesReadThisYear() -> Int {
        queue.sync {
            let year = String(Calendar.current.component(.year, from: Date()))
            return scalarInt("SELECT COUNT(DISTINCT comic_id) FROM reading_history WHERE strftime('%Y', read_at) = ?",
                             args: [year])
        }
    }

    func readingGoal(year: Int) -> Int {
        queue.sync {
            let v = scalarInt("SELECT goal_count FROM reading_goals WHERE year=?", args: [year])
            return v == 0 ? 52 : v
        }
    }

    func setReadingGoal(year: Int, count: Int) {
        queue.async {
            _ = self.run("INSERT OR REPLACE INTO reading_goals (year, goal_count) VALUES (?,?)", args: [year, count])
        }
    }

    /// Every calendar year that has at least one real reading session -- backs the year picker on
    /// the Year in Review screen, most recent first, so a user isn't stuck looking at a hardcoded
    /// "this year" that might be empty in their first days using the app.
    func availableReadingYears() -> [Int] {
        queue.sync {
            rows("SELECT DISTINCT strftime('%Y', read_at) FROM reading_history ORDER BY 1 DESC") { colText($0, 0) }
                .compactMap { Int($0 ?? "") }
        }
    }

    struct YearInReviewStats {
        let year: Int
        let issuesRead: Int
        let pagesRead: Int
        let topSeries: (name: String, count: Int)?
        let topPublisher: (name: String, count: Int)?
        let ratedCount: Int
        let averageRating: Double?
        let topRated: [(title: String, rating: Int)]
        let rereadCount: Int
        let longestStreakDays: Int
        let busiestMonthLabel: String?
    }

    /// A "wrapped"-style recap for one calendar year, built entirely from data the app already
    /// tracks day-to-day (reading sessions, diary entries) -- no new instrumentation needed, just
    /// year-scoped aggregation over what's already there.
    func yearInReview(year: Int) -> YearInReviewStats {
        queue.sync {
            let yearStr = String(year)

            let issuesRead = scalarInt(
                "SELECT COUNT(DISTINCT comic_id) FROM reading_history WHERE strftime('%Y', read_at) = ?", args: [yearStr])
            let pagesRead = scalarInt(
                "SELECT COALESCE(SUM(page_end - page_start + 1), 0) FROM reading_history WHERE strftime('%Y', read_at) = ?",
                args: [yearStr])

            let topSeries = rows("""
                SELECT c.series, COUNT(DISTINCT h.comic_id) as n
                FROM reading_history h JOIN comics c ON c.id = h.comic_id
                WHERE strftime('%Y', h.read_at) = ?
                GROUP BY c.publisher, c.series ORDER BY n DESC LIMIT 1
                """, args: [yearStr]) { (name: colText($0, 0) ?? "", count: colInt($0, 1)) }.first

            let topPublisher = rows("""
                SELECT c.publisher, COUNT(DISTINCT h.comic_id) as n
                FROM reading_history h JOIN comics c ON c.id = h.comic_id
                WHERE strftime('%Y', h.read_at) = ?
                GROUP BY c.publisher ORDER BY n DESC LIMIT 1
                """, args: [yearStr]) { (name: colText($0, 0) ?? "", count: colInt($0, 1)) }.first

            let topRated = rows("""
                SELECT c.title, d.rating FROM diary_entries d JOIN comics c ON c.id = d.comic_id
                WHERE strftime('%Y', d.logged_at) = ? AND d.rating >= 4
                ORDER BY d.rating DESC, d.logged_at DESC LIMIT 5
                """, args: [yearStr]) { (title: colText($0, 0) ?? "", rating: colInt($0, 1)) }

            let ratedCount = scalarInt(
                "SELECT COUNT(*) FROM diary_entries WHERE strftime('%Y', logged_at) = ? AND rating > 0", args: [yearStr])
            let ratings: [Int] = rows(
                "SELECT rating FROM diary_entries WHERE strftime('%Y', logged_at) = ? AND rating > 0", args: [yearStr]) { colInt($0, 0) }
            let averageRating = ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)

            let rereadCount = scalarInt(
                "SELECT COUNT(*) FROM diary_entries WHERE strftime('%Y', logged_at) = ? AND is_reread = 1", args: [yearStr])

            let distinctDays: [String] = rows(
                "SELECT DISTINCT date(read_at) as d FROM reading_history WHERE strftime('%Y', read_at) = ?", args: [yearStr]) { colText($0, 0) ?? "" }
            let longestStreakDays = longestStreak(dates: distinctDays)

            let busiestMonthNum = rows("""
                SELECT strftime('%m', read_at) as m, COUNT(DISTINCT comic_id) as n
                FROM reading_history WHERE strftime('%Y', read_at) = ?
                GROUP BY m ORDER BY n DESC LIMIT 1
                """, args: [yearStr]) { colText($0, 0) ?? "" }.first
            let busiestMonthLabel = busiestMonthNum.flatMap { $0.isEmpty ? nil : Self.monthName(from: $0) }

            return YearInReviewStats(
                year: year, issuesRead: issuesRead, pagesRead: pagesRead,
                topSeries: topSeries, topPublisher: topPublisher,
                ratedCount: ratedCount, averageRating: averageRating, topRated: topRated,
                rereadCount: rereadCount, longestStreakDays: longestStreakDays,
                busiestMonthLabel: busiestMonthLabel
            )
        }
    }

    private static func monthName(from monthNumber: String) -> String? {
        guard let n = Int(monthNumber), (1...12).contains(n) else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.monthSymbols[n - 1]
    }

    /// Longest run of consecutive calendar days with at least one reading session, within an
    /// arbitrary (not necessarily today-anchored) set of dates -- distinct from `computeStreak`,
    /// which only ever counts backward from today/yesterday for the *current* streak. This finds
    /// the best run anywhere in a bounded year, which could be months in the past.
    private func longestStreak(dates: [String]) -> Int {
        let cal = Calendar.current
        let days = dates.compactMap { Self.yyyyMMddFormatter.date(from: $0) }
            .map { cal.startOfDay(for: $0) }
            .sorted()
        guard !days.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for i in 1..<days.count {
            if let expected = cal.date(byAdding: .day, value: 1, to: days[i - 1]), expected == days[i] {
                current += 1
                longest = max(longest, current)
            } else if days[i] != days[i - 1] {
                current = 1
            }
        }
        return longest
    }

    func missingIssueNumbers(series: String, publisher: String) -> [String] {
        queue.sync {
            let nums = rows("""
                SELECT CAST(issue_number AS INTEGER) as n FROM comics
                WHERE deleted_at IS NULL AND series=? AND publisher=?
                  AND issue_number IS NOT NULL AND issue_number != ''
                  AND CAST(issue_number AS INTEGER) > 0
                ORDER BY n
            """, args: [series, publisher]) { colInt($0, 0) }
            guard nums.count > 1 else { return [] }
            var missing: [String] = []
            for i in 1..<nums.count {
                let prev = nums[i-1], curr = nums[i]
                if curr - prev > 1 {
                    for n in (prev+1)..<curr { missing.append("#\(n)") }
                }
            }
            return missing
        }
    }

    func trashedComics() -> [Comic] {
        queue.sync {
            let sql = "\(comicSelect) WHERE c.deleted_at IS NOT NULL ORDER BY c.deleted_at DESC"
            return rows(sql, map: comicRow)
        }
    }

    func restoreComic(id: Int64) {
        queue.async { _ = self.run("UPDATE comics SET deleted_at = NULL WHERE id = ?", args: [id]) }
    }

    func restore(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            var stmt: OpaquePointer?
            let sql = "UPDATE comics SET deleted_at = NULL WHERE id IN (\(ph))"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            for (i, id) in ids.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), id) }
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

}
