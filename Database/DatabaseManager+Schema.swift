import Foundation
import SQLite3

extension DatabaseManager {
    func migrate() {
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
            rating   INTEGER CHECK(rating BETWEEN 0 AND 5),
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
        exec("ALTER TABLE tier_lists ADD COLUMN rating INTEGER")
        exec("ALTER TABLE tier_lists ADD COLUMN review TEXT")
        exec("ALTER TABLE tier_lists ADD COLUMN cover_image_path TEXT")

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

        // Whatever folder(s) sit between the Character folder and the Series folder itself (e.g.
        // "Batman (Modern)" in DC/Batman/Batman (Modern)/Batman (2016)/) -- folderComponents used
        // to silently discard everything except the first, second, and last folder, so a 4th
        // level a user built to group volumes/eras existed on disk but was invisible everywhere
        // in the app. Nil for the (very common) 1-3 level layout, where there's no such folder.
        exec("ALTER TABLE comics ADD COLUMN folder_group TEXT")

        // Where a deleted comic's file currently sits in the system Trash, if it was moved there
        // (nil if trashing wasn't supported/failed, in which case the file was simply left alone).
        // Needed so restoring from the in-app Trash screen (Settings -> View Trash), which can
        // happen long after the delete's own undo toast has expired or the app's been relaunched,
        // still knows where to move the file back from -- without this, that restore path would
        // bring the database row back while the file stayed stranded in the system Trash.
        exec("ALTER TABLE comics ADD COLUMN trashed_file_path TEXT")

        // Distinguishes a comic soft-deleted because the user chose to delete it from one that
        // was soft-deleted because its file vanished from disk (drive unplugged, moved/renamed
        // outside the app) -- previously both looked identical in the Trash screen, and
        // "Restore" on a still-missing file would silently bring the row back pointing at
        // nothing. NULL (pre-existing soft-deletes) is treated as "user" by the app.
        exec("ALTER TABLE comics ADD COLUMN deleted_reason TEXT")

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
        allowUnratedReviewsIfNeeded()

        // Decouples "finished" from the raw resume position: `current_page` alone used to double
        // as completion state, so scrubbing the reader's page slider to the last page (without
        // reading through it) instantly marked the issue finished. This is set only via
        // markFinished()/markUnfinished() -- sticky once set, and only from genuine sequential
        // reading or an explicit Mark Read/Unread action, never from jump-style navigation.
        exec("ALTER TABLE reading_progress ADD COLUMN finished_at TIMESTAMP")
    }

    func recomputeOnceAfterUpgradeIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        let alreadyRun = scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'readingOrderRecomputeGateV1'") > 0
        guard !alreadyRun else { return }
        positionSpecialsChronologically()
        recomputeReadingOrder()
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('readingOrderRecomputeGateV1')")
    }

    func resortSpecialIssuesIfNeeded() {
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

    /// `ratings.rating` had `CHECK(rating BETWEEN 1 AND 5)`, but `setComicReview` -- and every
    /// other read path in this file (`COALESCE(r.rating, 0)`) -- has always treated 0 as the
    /// real, valid "no rating yet" sentinel. Writing a review for a comic that had never been
    /// rated inserted `rating=0`, which the CHECK constraint silently rejected: `run()`'s Bool
    /// result was discarded at that call site, so the review just never saved, with no error
    /// surfaced anywhere. Rebuilds the table with the constraint the rest of the app already
    /// assumed was true (SQLite can't ALTER an existing CHECK constraint in place).
    func allowUnratedReviewsIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        let alreadyRun = scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'ratingsAllowZeroV1'") > 0
        guard !alreadyRun else { return }
        _ = inTransaction {
            exec("ALTER TABLE ratings RENAME TO ratings_old_ratingsAllowZeroV1")
            exec("""
                CREATE TABLE ratings (
                    comic_id INTEGER PRIMARY KEY REFERENCES comics(id),
                    rating   INTEGER CHECK(rating BETWEEN 0 AND 5),
                    review   TEXT
                )
                """)
            exec("INSERT INTO ratings SELECT * FROM ratings_old_ratingsAllowZeroV1")
            exec("DROP TABLE ratings_old_ratingsAllowZeroV1")
            return true
        }
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('ratingsAllowZeroV1')")
    }

    func widenMainlinePositionStrideIfNeeded() {
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
    func makeSeriesLinksVolumeAwareIfNeeded() {
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

}
