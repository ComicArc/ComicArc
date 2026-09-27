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
            comic_id     INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE,
            current_page INTEGER DEFAULT 0,
            last_read    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS favorites (
            comic_id INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE
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

        // Decouples "finished" from the raw resume position: `current_page` alone used to double
        // as completion state, so scrubbing the reader's page slider to the last page (without
        // reading through it) instantly marked the issue finished. This is set only via
        // markFinished()/markUnfinished() -- sticky once set, and only from genuine sequential
        // reading or an explicit Mark Read/Unread action, never from jump-style navigation.
        exec("ALTER TABLE reading_progress ADD COLUMN finished_at TIMESTAMP")

        addCascadeToProgressIfNeeded()
        applyManualOrdersToPositionIfNeeded()
        dropRemovedFeatureDataIfNeeded()
        moveReadingListIntoPathIfNeeded()
    }

    /// Series order now comes from `comics.position` alone (the intelligent reading-order engine
    /// and its `reading_order_position` column are gone). Manual Series Manager orders used to
    /// live only in `reading_order_overrides` and were re-applied through that column, so rescans
    /// had long since reseeded `position` underneath them -- copy them back once. Only whole-series
    /// overrides are real Series Manager orders; a partial set can only come from the removed
    /// "confirm auto-placement" review, whose positions used the old engine's numbering, so those
    /// are dropped rather than mixed into a series ordered on a different scale. Every other
    /// comic's position is reseeded (issue number, specials after regular issues) since the old
    /// engine also moved specials' base positions.
    func applyManualOrdersToPositionIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        guard scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'manualOrdersToPositionV1'") == 0 else { return }
        _ = inTransaction {
            let pruned = exec("""
            DELETE FROM reading_order_overrides WHERE comic_id IN (
                SELECT c.id FROM comics c
                WHERE EXISTS (
                    SELECT 1 FROM comics s
                    WHERE s.publisher = c.publisher AND s.series = c.series AND s.deleted_at IS NULL
                      AND s.id NOT IN (SELECT comic_id FROM reading_order_overrides)
                )
            )
            """)
            let reseeded = exec("""
            UPDATE comics SET position =
                is_special_issue(issue_number, title, series) * \(ComicSortClassifier.specialBandOffset)
                + COALESCE(CAST(NULLIF(issue_number,'') AS INTEGER), id) * \(ComicSortClassifier.mainlinePositionStride)
            WHERE id NOT IN (SELECT comic_id FROM reading_order_overrides)
            """)
            let applied = exec("""
            UPDATE comics SET position = (SELECT o.position FROM reading_order_overrides o WHERE o.comic_id = comics.id)
            WHERE id IN (SELECT comic_id FROM reading_order_overrides)
            """)
            return pruned && reseeded && applied
        }
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('manualOrdersToPositionV1')")
    }

    /// Rebuilds `reading_progress` with `ON DELETE CASCADE` (SQLite can't add a REFERENCES clause
    /// in place), so purging a comic from Trash can't leave its progress row orphaned.
    func addCascadeToProgressIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        let alreadyRun = scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'progressRatingsCascadeV1'") > 0
        guard !alreadyRun else { return }
        _ = inTransaction {
            exec("ALTER TABLE reading_progress RENAME TO reading_progress_old_cascadeV1")
            exec("""
            CREATE TABLE reading_progress (
                comic_id     INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE,
                current_page INTEGER DEFAULT 0,
                last_read    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                finished_at  TIMESTAMP
            )
            """)
            exec("""
            INSERT INTO reading_progress (comic_id, current_page, last_read, finished_at)
            SELECT comic_id, current_page, last_read, finished_at FROM reading_progress_old_cascadeV1
            """)
            exec("DROP TABLE reading_progress_old_cascadeV1")

            return true
        }
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('progressRatingsCascadeV1')")
    }

    /// Drops the tables and columns of features removed from ComicArc (ratings/reviews, the Diary,
    /// series links, Tier Lists, the intelligent reading-order engine, and the offline comics
    /// database). Each statement tolerates the object already being gone.
    func dropRemovedFeatureDataIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        guard scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'dropRemovedFeaturesV1'") == 0 else { return }
        for index in ["idx_comics_gcd_manual", "idx_tier_list_items_tier_list_id", "idx_tier_list_items_comic_id",
                      "idx_diary_comic_id", "idx_diary_logged_at"] {
            exec("DROP INDEX IF EXISTS \(index)")
        }
        // comic_shelves/shelves/list_items/lists/saved_filters: tables from much older versions
        // that nothing has read since.
        for table in ["ratings", "diary_entries", "series_links", "tier_list_items", "tier_lists",
                      "comic_shelves", "shelves", "list_items", "lists", "saved_filters"] {
            exec("DROP TABLE IF EXISTS \(table)")
        }
        for column in ["reading_order_position", "reading_order_confidence", "reading_order_reason",
                       "gcd_issue_id", "gcd_cover_date", "gcd_match_confidence", "gcd_match_reason",
                       "gcd_series_name", "gcd_issue_number", "gcd_match_source"] {
            exec("ALTER TABLE comics DROP COLUMN \(column)")
        }
        exec("ALTER TABLE runs DROP COLUMN rating")
        exec("ALTER TABLE runs DROP COLUMN review")
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('dropRemovedFeaturesV1')")
        exec("VACUUM")
    }

    /// The Reading List used to be its own table; it's now an ordinary Reading Path titled
    /// "Reading List". Moves any existing entries over (oldest first) and drops the old table.
    func moveReadingListIntoPathIfNeeded() {
        exec("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY)")
        guard scalarInt("SELECT COUNT(*) FROM migrations WHERE name = 'readingListToPathV1'") == 0 else { return }
        let hasOldTable = scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'reading_list'") > 0
        if hasOldTable && scalarInt("SELECT COUNT(*) FROM reading_list") > 0 {
            _ = inTransaction {
                if scalarInt("SELECT COALESCE(\(Self.readingListRunIdSQL), 0)") == 0,
                   run("INSERT INTO runs (title, description) VALUES (?, '')", args: [Self.readingListTitle]) == -1 {
                    return false
                }
                let start = scalarInt(
                    "SELECT COALESCE(MAX(position), -1) FROM run_items WHERE run_id = \(Self.readingListRunIdSQL)")
                return exec("""
                    INSERT OR IGNORE INTO run_items (run_id, comic_id, position)
                    SELECT \(Self.readingListRunIdSQL), rl.comic_id,
                           \(start) + ROW_NUMBER() OVER (ORDER BY rl.added_at, rl.comic_id)
                    FROM reading_list rl JOIN comics c ON c.id = rl.comic_id
                    """)
            }
        }
        exec("DROP TABLE IF EXISTS reading_list")
        exec("INSERT OR IGNORE INTO migrations (name) VALUES ('readingListToPathV1')")
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

}
