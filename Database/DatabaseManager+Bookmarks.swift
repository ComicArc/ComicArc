import Foundation
import SQLite3

extension DatabaseManager {
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

}
