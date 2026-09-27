import Foundation
import SQLite3

extension DatabaseManager {
    func runsContaining(comicId: Int64) -> [Run] {
        queue.sync {
            rows("""
                SELECT r.id, r.title, COALESCE(r.description,''), r.buy_link
                FROM runs r JOIN run_items ri ON ri.run_id = r.id
                WHERE ri.comic_id = ? ORDER BY r.created_at
            """, args: [comicId]) { r in
                Run(id: colInt64(r, 0), title: colText(r, 1) ?? "", description: colText(r, 2) ?? "",
                    buyLink: colText(r, 3))
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

    func allRuns() -> [Run] {
        queue.sync {
            let sql = """
                SELECT r.id, r.title, COALESCE(r.description,''), r.buy_link,
                       COUNT(ri.id) as total,
                       SUM(CASE WHEN rp.finished_at IS NOT NULL THEN 1 ELSE 0 END) as read_ct,
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
                    buyLink: colText(s, 3),
                    comicCount: colInt(s, 4), readCount: colInt(s, 5), coverImagePath: colText(s, 6))
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

    func setRunItemNotes(_ itemId: Int64, notes: String) {
        queue.sync {
            _ = run("UPDATE run_items SET notes = ? WHERE id = ?",
                    args: [notes.isEmpty ? nil : notes, itemId])
        }
    }

    // MARK: - Reading Path sync

    /// Every Reading Path as (title, description, ordered file hashes) -- file hashes, not ids,
    /// since ids mean nothing across two independently scanned libraries.
    func pathSyncSnapshot() -> [(title: String, description: String, hashes: [String])] {
        queue.sync {
            let runs = rows("SELECT id, title, COALESCE(description,'') FROM runs ORDER BY COALESCE(position, id * -1)") {
                (id: colInt64($0, 0), title: colText($0, 1) ?? "", description: colText($0, 2) ?? "")
            }
            return runs.map { run in
                let hashes = rows("""
                    SELECT c.file_hash FROM run_items ri JOIN comics c ON c.id = ri.comic_id
                    WHERE ri.run_id = ? AND c.file_hash IS NOT NULL AND c.deleted_at IS NULL
                    ORDER BY ri.position
                    """, args: [run.id]) { colText($0, 0) ?? "" }
                return (title: run.title, description: run.description, hashes: hashes)
            }
        }
    }

    /// Additive merge of another device's Reading Paths, matched by title: missing paths are
    /// created, and comics missing from a path are appended in the other device's order. Never
    /// removes anything, so a sync can't delete a path or an entry.
    func applySyncedPaths(_ paths: [(title: String, description: String, hashes: [String])]) -> (created: Int, added: Int) {
        queue.sync {
            var created = 0, added = 0
            _ = inTransaction {
                for path in paths where !path.title.isEmpty {
                    var runId = Int64(scalarInt("SELECT COALESCE((SELECT id FROM runs WHERE title = ? ORDER BY id LIMIT 1), 0)",
                                                args: [path.title]))
                    if runId == 0 {
                        runId = run("INSERT INTO runs (title, description) VALUES (?, ?)", args: [path.title, path.description])
                        guard runId > 0 else { return false }
                        created += 1
                    }
                    var existing = Set(rows("SELECT comic_id FROM run_items WHERE run_id = ?", args: [runId]) { colInt64($0, 0) })
                    var next = scalarInt("SELECT COALESCE(MAX(position), -1) + 1 FROM run_items WHERE run_id = ?", args: [runId])
                    for hash in path.hashes {
                        guard let comicId = rows("SELECT id FROM comics WHERE file_hash = ? AND deleted_at IS NULL LIMIT 1",
                                                 args: [hash], map: { colInt64($0, 0) }).first,
                              existing.insert(comicId).inserted else { continue }
                        guard run("INSERT INTO run_items (run_id, comic_id, position) VALUES (?,?,?)",
                                  args: [runId, comicId, next]) > 0 else { return false }
                        next += 1; added += 1
                    }
                }
                return true
            }
            return (created, added)
        }
    }
}
