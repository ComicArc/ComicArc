import Foundation
import SQLite3

extension DatabaseManager {
    func clearAll() {
        queue.sync {
            // A force-quit/crash mid-sequence (this is a user-triggered destructive "reset
            // library" action) must not leave some tables wiped and others not -- inTransaction
            // rolls back the whole reset if any single DELETE fails, rather than committing
            // whatever happened to complete first.
            let tables = [
                "reading_history", "reading_progress", "reading_goals", "bookmarks", "ratings",
                "favorites", "reading_list", "comic_tags", "series_covers", "run_items", "runs", "tags",
                // "Clear All" is a full factory reset, not just a comics wipe -- these have no
                // foreign key to comics (keyed by series/publisher name, or independent
                // user-created collections) so they'd otherwise silently survive a reset untouched.
                "tier_list_items", "tier_lists", "diary_entries", "series_links",
                "reading_order_overrides", "metadata_conflicts", "series_reader_prefs",
                "character_covers", "series_order", "character_order", "publisher_order", "comics",
            ]
            inTransaction {
                tables.allSatisfy { exec("DELETE FROM \($0)") }
            }
        }
    }

    func trashedComics() -> [Comic] {
        queue.sync {
            let sql = "\(comicSelect) WHERE c.deleted_at IS NOT NULL ORDER BY c.deleted_at DESC"
            return rows(sql, map: comicRow)
        }
    }

    func setTrashedFilePath(id: Int64, path: String?) {
        queue.sync { _ = run("UPDATE comics SET trashed_file_path = ? WHERE id = ?", args: [path, id]) }
    }

    func trashedFilePath(id: Int64) -> String? {
        queue.sync {
            let sql = "SELECT trashed_file_path FROM comics WHERE id = ?"
            var raw: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindArgs(stmt, args: [id])
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return colText(stmt, 0)
        }
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
