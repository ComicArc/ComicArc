import Foundation
import SQLite3

extension DatabaseManager {
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

    // `reading_order_overrides` holds manual Series Manager orders, so a rescan that reseeds
    // `position` (see `batchUpdateFolderMeta`) never wipes them.
    func setReadingOrderOverride(comicId: Int64, position: Int, reason: String = "Manually placed") {
        queue.sync {
            _ = run("""
                INSERT OR REPLACE INTO reading_order_overrides (comic_id, position, reason) VALUES (?, ?, ?)
                """, args: [comicId, position, reason])
            _ = run("UPDATE comics SET position = ? WHERE id = ?", args: [position, comicId])
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

}
