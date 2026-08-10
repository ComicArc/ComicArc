import Foundation
import SQLite3

extension DatabaseManager {
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

    func tierListsContaining(comicId: Int64) -> [TierList] {
        queue.sync {
            rows("""
                SELECT tl.id, tl.title, COALESCE(tl.description,''), tl.created_at,
                       COALESCE(tl.rating,0), tl.review, tl.cover_image_path
                FROM tier_lists tl JOIN tier_list_items tli ON tli.tier_list_id = tl.id
                WHERE tli.comic_id = ? ORDER BY tl.created_at
            """, args: [comicId]) { r in
                TierList(id: colInt64(r, 0), title: colText(r, 1) ?? "", description: colText(r, 2) ?? "",
                          createdAt: colText(r, 3) ?? "",
                          rating: colInt(r, 4) > 0 ? colInt(r, 4) : nil,
                          review: colText(r, 5), coverImagePath: colText(r, 6))
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
            SELECT ri.id, ri.position, COALESCE(ri.notes,''), \(comicColumns)
            FROM run_items ri
            JOIN comics c ON ri.comic_id = c.id AND c.deleted_at IS NULL
            \(comicJoins)
            WHERE ri.run_id = ? ORDER BY ri.position
            """
            return rows(sql, args: [runId]) { s -> RunItem in
                RunItem(id: colInt64(s, 0), comic: comicRow(s, offset: 3),
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

    func allTierLists() -> [TierList] {
        queue.sync {
            let sql = """
                SELECT tl.id, tl.title, COALESCE(tl.description,''), tl.created_at, COUNT(tli.id) as total,
                       COALESCE(tl.rating,0), tl.review, tl.cover_image_path
                FROM tier_lists tl
                LEFT JOIN tier_list_items tli ON tli.tier_list_id = tl.id
                GROUP BY tl.id
                ORDER BY COALESCE(tl.position, tl.id * -1)
            """
            return rows(sql, map: { s in
                TierList(id: colInt64(s, 0), title: colText(s, 1) ?? "", description: colText(s, 2) ?? "",
                          createdAt: colText(s, 3) ?? "", comicCount: colInt(s, 4),
                          rating: colInt(s, 5) > 0 ? colInt(s, 5) : nil,
                          review: colText(s, 6), coverImagePath: colText(s, 7))
            })
        }
    }

    @discardableResult
    func createTierList(title: String, description: String) -> Int64 {
        queue.sync { run("INSERT INTO tier_lists (title, description) VALUES (?,?)", args: [title, description]) }
    }

    func setTierListCover(tierListId: Int64, imagePath: String) {
        queue.sync { _ = run("UPDATE tier_lists SET cover_image_path = ? WHERE id = ?", args: [imagePath, tierListId]) }
    }

    func clearTierListCover(tierListId: Int64) {
        queue.sync { _ = run("UPDATE tier_lists SET cover_image_path = NULL WHERE id = ?", args: [tierListId]) }
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
            SELECT tli.id, tli.tier, tli.position, \(comicColumns)
            FROM tier_list_items tli
            JOIN comics c ON tli.comic_id = c.id AND c.deleted_at IS NULL
            \(comicJoins)
            WHERE tli.tier_list_id = ? ORDER BY tli.position
            """
            return rows(sql, args: [tierListId]) { s -> TierListItem in
                TierListItem(id: colInt64(s, 0), comic: comicRow(s, offset: 3),
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

    func setTierListRating(_ tierListId: Int64, rating: Int, review: String?) {
        queue.sync {
            _ = run("UPDATE tier_lists SET rating = ?, review = ? WHERE id = ?",
                    args: [rating > 0 ? rating : nil, review, tierListId])
        }
    }

}
