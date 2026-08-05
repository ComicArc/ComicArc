import Foundation
import SQLite3

extension DatabaseManager {
    private struct RawDiaryEntry {
        let id: Int64; let comicId: Int64; let rating: Int; let review: String?; let loggedAt: String; let isReread: Bool
    }

    /// Shared by `diaryEntries` and `onThisDayEntries`, which differ only in their WHERE clause --
    /// both fetch the child rows, then batch-resolve their comics via one IN query rather than
    /// looking each one up individually.
    private func diaryEntries(where clause: String, limit: Int) -> [DiaryEntry] {
        queue.sync {
            let raw: [RawDiaryEntry] = rows("""
                SELECT id, comic_id, rating, review, logged_at, is_reread
                FROM diary_entries
                \(clause)
                ORDER BY logged_at DESC, id DESC
                LIMIT ?
                """, args: [limit], map: { s in
                    RawDiaryEntry(id: colInt64(s, 0), comicId: colInt64(s, 1), rating: colInt(s, 2), review: colText(s, 3),
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

    func diaryEntries(limit: Int = 500) -> [DiaryEntry] {
        diaryEntries(where: "", limit: limit)
    }

    /// Diary entries logged on this same calendar day in a previous year -- a "memories" callback,
    /// same 'localtime' conversion already used by `_logDiaryEntryUnlocked`'s same-day collapse
    /// check, so "today" here means the device's local day, not the UTC day `logged_at` is stored in.
    func onThisDayEntries(limit: Int = 20) -> [DiaryEntry] {
        diaryEntries(where: """
            WHERE strftime('%m-%d', logged_at, 'localtime') = strftime('%m-%d', 'now', 'localtime')
              AND strftime('%Y', logged_at, 'localtime') != strftime('%Y', 'now', 'localtime')
            """, limit: limit)
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

}
