import Foundation
import SQLite3

extension DatabaseManager {
    func clearAll() {
        queue.sync {
            // One transaction so a reset never half-completes.
            let tables = [
                "reading_history", "reading_progress", "reading_goals", "bookmarks",
                "favorites", "comic_tags", "series_covers", "run_items", "runs", "tags",
                // Tables keyed by name rather than comic id, so they need clearing explicitly.
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

    /// Permanently deletes soft-deleted rows (cascading to their bookmarks, progress, tags and path
    /// entries). Never touches files.
    func purge(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            _ = inTransaction {
                idChunks(ids).allSatisfy { chunk in
                    let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                    return run("DELETE FROM comics WHERE deleted_at IS NOT NULL AND id IN (\(placeholders))",
                                args: chunk.map { $0 as Any? }) != -1
                }
            }
        }
    }

    func purgeAllTrashed() {
        queue.sync {
            _ = run("DELETE FROM comics WHERE deleted_at IS NOT NULL")
        }
    }
}
