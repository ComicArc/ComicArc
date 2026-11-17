import Foundation

extension Database {
    func readingPaths() async throws -> [ReadingPath] {
        try await read { db in
            try db.query("""
                SELECT r.id, r.title, COALESCE(r.description, ''), r.cover_image_path,
                       COUNT(c.id), SUM(rp.finished_at IS NOT NULL),
                       (SELECT ri2.comic_id FROM run_items ri2 JOIN comics c2 ON c2.id = ri2.comic_id AND c2.deleted_at IS NULL
                        WHERE ri2.run_id = r.id ORDER BY ri2.position LIMIT 1)
                FROM runs r
                LEFT JOIN run_items ri ON ri.run_id = r.id
                LEFT JOIN comics c ON c.id = ri.comic_id AND c.deleted_at IS NULL
                LEFT JOIN reading_progress rp ON rp.comic_id = c.id
                GROUP BY r.id ORDER BY COALESCE(r.position, 999999), r.id
                """) { r in
                ReadingPath(id: r.int64(0), title: r.string(1) ?? "", description: r.string(2) ?? "",
                            coverImagePath: r.string(3), count: r.int(4), finished: r.int(5),
                            firstComicID: r.isNull(6) ? nil : r.int64(6))
            }
        }
    }

    func pathItems(_ pathID: Int64) async throws -> [ReadingPathItem] {
        try await read { db in
            try db.query("""
                SELECT ri.id, COALESCE(ri.notes, ''), \(ComicSQL.columns)
                FROM run_items ri JOIN comics c ON c.id = ri.comic_id AND c.deleted_at IS NULL \(ComicSQL.joins)
                WHERE ri.run_id = ? ORDER BY ri.position, ri.id
                """, [pathID]) { r in
                ReadingPathItem(id: r.int64(0), comic: ComicSQL.comic(from: r, offset: 2), notes: r.string(1) ?? "")
            }
        }
    }

    func pathsContaining(comicID: Int64) async throws -> [ReadingPath] {
        try await read { db in
            try db.query("""
                SELECT r.id, r.title, COALESCE(r.description,''), r.cover_image_path FROM runs r
                JOIN run_items ri ON ri.run_id = r.id WHERE ri.comic_id = ? ORDER BY r.title
                """, [comicID]) {
                ReadingPath(id: $0.int64(0), title: $0.string(1) ?? "", description: $0.string(2) ?? "",
                            coverImagePath: $0.string(3), count: 0, finished: 0, firstComicID: nil)
            }
        }
    }

    @discardableResult
    func createPath(title: String, description: String = "") async throws -> Int64 {
        try await write { db in
            let next = try db.scalarInt("SELECT COALESCE(MAX(position), -1) + 1 FROM runs")
            try db.run("INSERT INTO runs (title, description, position) VALUES (?,?,?)", [title, description, next])
            return db.lastInsertRowID
        }
    }

    func updatePath(_ id: Int64, title: String, description: String) async throws {
        try await write { db in try db.run("UPDATE runs SET title = ?, description = ? WHERE id = ?", [title, description, id]) }
    }

    func setPathCover(_ id: Int64, imagePath: String?) async throws {
        try await write { db in try db.run("UPDATE runs SET cover_image_path = ? WHERE id = ?", [imagePath, id]) }
    }

    func deletePath(_ id: Int64) async throws {
        try await write { db in try db.run("DELETE FROM runs WHERE id = ?", [id]) }
    }

    func reorderPaths(_ ids: [Int64]) async throws {
        try await write { db in
            try db.transaction { try db.runBatch("UPDATE runs SET position = ? WHERE id = ?", ids.enumerated().map { [$0.offset, $0.element] }) }
        }
    }

    /// Appends comics in order, skipping any already in the path. Returns the ids actually added.
    @discardableResult
    func addToPath(_ pathID: Int64, comicIDs: [Int64]) async throws -> [Int64] {
        try await write { db in
            try db.transaction {
                let existing = Set(try db.query("SELECT comic_id FROM run_items WHERE run_id = ?", [pathID]) { $0.int64(0) })
                let added = comicIDs.filter { !existing.contains($0) }.reduce(into: [Int64]()) { if !$0.contains($1) { $0.append($1) } }
                var next = try db.scalarInt("SELECT COALESCE(MAX(position), -1) + 1 FROM run_items WHERE run_id = ?", [pathID])
                for id in added {
                    try db.run("INSERT INTO run_items (run_id, comic_id, position) VALUES (?,?,?)", [pathID, id, next])
                    next += 1
                }
                return added
            }
        }
    }

    func removeFromPath(_ pathID: Int64, comicIDs: [Int64]) async throws {
        try await write { db in
            try db.transaction {
                for id in comicIDs { try db.run("DELETE FROM run_items WHERE run_id = ? AND comic_id = ?", [pathID, id]) }
            }
        }
    }

    func reorderPath(_ pathID: Int64, itemIDs: [Int64]) async throws {
        try await write { db in
            try db.transaction {
                try db.runBatch("UPDATE run_items SET position = ? WHERE id = ? AND run_id = ?",
                                itemIDs.enumerated().map { [$0.offset, $0.element, pathID] })
            }
        }
    }

    func setPathItemNotes(_ itemID: Int64, notes: String) async throws {
        try await write { db in try db.run("UPDATE run_items SET notes = ? WHERE id = ?", [notes, itemID]) }
    }

    /// The built-in Reading List path, created on first use.
    func readingListID(create: Bool) async throws -> Int64? {
        if let id = try await read({ db in
            try db.first("SELECT id FROM runs WHERE title = ? ORDER BY id", [ReadingPath.readingListTitle]) { $0.int64(0) }
        }) { return id }
        return create ? try await createPath(title: ReadingPath.readingListTitle) : nil
    }

    func setInReadingList(_ ids: [Int64], _ on: Bool) async throws {
        guard let listID = try await readingListID(create: on) else { return }
        if on { try await addToPath(listID, comicIDs: ids) } else { try await removeFromPath(listID, comicIDs: ids) }
    }
}
