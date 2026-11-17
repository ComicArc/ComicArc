import Foundation

extension Database {
    // MARK: - Reading progress

    func saveProgress(comicID: Int64, page: Int) async throws {
        try await write { db in
            try db.run("""
                INSERT INTO reading_progress (comic_id, current_page, last_read) VALUES (?, ?, datetime('now'))
                ON CONFLICT(comic_id) DO UPDATE SET current_page = excluded.current_page, last_read = excluded.last_read
                """, [comicID, page])
        }
    }

    /// `finished_at` is sticky: set by reading to the end or Mark as Read, never cleared by a reread.
    func markFinished(_ ids: [Int64], lastPages: [Int64: Int] = [:]) async throws {
        try await write { db in
            try db.transaction {
                for id in ids {
                    let page = lastPages[id]
                    try db.run("""
                        INSERT INTO reading_progress (comic_id, current_page, last_read, finished_at)
                        VALUES (?, COALESCE(?, 0), datetime('now'), datetime('now'))
                        ON CONFLICT(comic_id) DO UPDATE SET finished_at = COALESCE(finished_at, datetime('now')),
                            current_page = COALESCE(?, current_page), last_read = datetime('now')
                        """, [id, page, page])
                }
            }
        }
    }

    func markUnread(_ ids: [Int64]) async throws {
        try await write { db in
            try db.transaction {
                for id in ids {
                    try db.run("UPDATE reading_progress SET finished_at = NULL, current_page = 0 WHERE comic_id = ?", [id])
                }
            }
        }
    }

    func logReadingSession(comicID: Int64, from start: Int, to end: Int) async throws {
        guard end != start || end > 0 else { return }
        try await write { db in
            try db.run("INSERT INTO reading_history (comic_id, page_start, page_end) VALUES (?,?,?)",
                       [comicID, min(start, end), max(start, end)])
        }
    }

    // MARK: - Flags

    func setFavorite(_ ids: [Int64], _ on: Bool) async throws {
        try await write { db in
            try db.transaction {
                for id in ids {
                    try db.run(on ? "INSERT OR IGNORE INTO favorites (comic_id) VALUES (?)"
                                  : "DELETE FROM favorites WHERE comic_id = ?", [id])
                }
            }
        }
    }

    func setNotes(_ notes: String?, comicID: Int64) async throws {
        try await write { db in
            try db.run("UPDATE comics SET notes = ? WHERE id = ?", [notes?.isEmpty == true ? nil : notes, comicID])
        }
    }

    /// Editable metadata. Editing marks the comic so a rescan never overwrites the change.
    struct MetadataEdit: Sendable {
        var title: String
        var series: String
        var publisher: String
        var issueNumber: String?
        var year: Int?
        var writer: String?
        var penciller: String?
        var storyArc: String?
    }

    func updateMetadata(_ e: MetadataEdit, comicID: Int64) async throws {
        try await write { db in
            try db.run("""
                UPDATE comics SET title = ?, series = ?, publisher = ?, issue_number = ?, year = ?, writer = ?,
                    penciller = ?, story_arc = ?, meta_edited = 1 WHERE id = ?
                """, [e.title, e.series, e.publisher, e.issueNumber, e.year, e.writer, e.penciller, e.storyArc, comicID])
        }
    }

    /// Moves comics to another series and/or publisher (bulk reassign).
    func reassign(_ ids: [Int64], series: String?, publisher: String?) async throws {
        try await write { db in
            try db.transaction {
                for id in ids {
                    if let series { try db.run("UPDATE comics SET series = ?, meta_edited = 1 WHERE id = ?", [series, id]) }
                    if let publisher { try db.run("UPDATE comics SET publisher = ?, meta_edited = 1 WHERE id = ?", [publisher, id]) }
                }
            }
        }
    }

    func identitySnapshot(_ ids: [Int64]) async throws -> [Int64: (series: String, publisher: String)] {
        let comics = try await comics(ids: ids)
        return Dictionary(uniqueKeysWithValues: comics.map { ($0.id, ($0.series, $0.publisher)) })
    }

    // MARK: - Tags

    func allTags() async throws -> [Tag] {
        try await read { db in
            try db.query("""
                SELECT t.id, t.name, COUNT(c.id) FROM tags t
                LEFT JOIN comic_tags ct ON ct.tag_id = t.id
                LEFT JOIN comics c ON c.id = ct.comic_id AND c.deleted_at IS NULL
                GROUP BY t.id HAVING COUNT(c.id) > 0 ORDER BY t.name COLLATE NOCASE
                """) { Tag(id: $0.int64(0), name: $0.string(1) ?? "", count: $0.int(2)) }
        }
    }

    func tags(comicID: Int64) async throws -> [Tag] {
        try await read { db in
            try db.query("SELECT t.id, t.name FROM tags t JOIN comic_tags ct ON ct.tag_id = t.id WHERE ct.comic_id = ? ORDER BY t.name COLLATE NOCASE",
                         [comicID]) { Tag(id: $0.int64(0), name: $0.string(1) ?? "", count: 0) }
        }
    }

    func addTag(_ name: String, to ids: [Int64]) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try await write { db in
            try db.transaction {
                try db.run("INSERT OR IGNORE INTO tags (name, category) VALUES (?, 'Custom')", [name])
                let tagID = try db.scalarInt("SELECT id FROM tags WHERE name = ?", [name])
                try db.runBatch("INSERT OR IGNORE INTO comic_tags (comic_id, tag_id) VALUES (?,?)", ids.map { [$0, tagID] })
            }
        }
    }

    func removeTag(_ tagID: Int64, from comicID: Int64) async throws {
        try await write { db in try db.run("DELETE FROM comic_tags WHERE comic_id = ? AND tag_id = ?", [comicID, tagID]) }
    }

    /// Renames a tag; if the new name already exists, the two tags are merged.
    func renameTag(_ tagID: Int64, to newName: String) async throws {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        try await write { db in
            try db.transaction {
                if let existing = try db.first("SELECT id FROM tags WHERE name = ? AND id != ?", [newName, tagID], { $0.int64(0) }) {
                    try db.run("INSERT OR IGNORE INTO comic_tags (comic_id, tag_id) SELECT comic_id, ? FROM comic_tags WHERE tag_id = ?",
                               [existing, tagID])
                    try db.run("DELETE FROM tags WHERE id = ?", [tagID])
                } else {
                    try db.run("UPDATE tags SET name = ? WHERE id = ?", [newName, tagID])
                }
            }
        }
    }

    func deleteTag(_ tagID: Int64) async throws {
        try await write { db in try db.run("DELETE FROM tags WHERE id = ?", [tagID]) }
    }

    // MARK: - Bookmarks and highlights

    func bookmarks(comicID: Int64) async throws -> [Bookmark] {
        try await read { db in
            try db.query("SELECT id, comic_id, page, label, is_favorite, created_at FROM bookmarks WHERE comic_id = ? ORDER BY page",
                         [comicID], Self.bookmark)
        }
    }

    /// Adds or removes a bookmark on `page`. Returns whether the page is now bookmarked.
    @discardableResult
    func toggleBookmark(comicID: Int64, page: Int) async throws -> Bool {
        try await write { db in
            if try db.run("DELETE FROM bookmarks WHERE comic_id = ? AND page = ?", [comicID, page]) > 0 { return false }
            try db.run("INSERT INTO bookmarks (comic_id, page, label) VALUES (?,?,'')", [comicID, page])
            return true
        }
    }

    /// Highlighting an unbookmarked page bookmarks it too.
    func setHighlight(comicID: Int64, page: Int, on: Bool, label: String? = nil) async throws {
        try await write { db in
            try db.run("""
                INSERT INTO bookmarks (comic_id, page, label, is_favorite) VALUES (?, ?, COALESCE(?, ''), ?)
                ON CONFLICT(comic_id, page) DO UPDATE SET is_favorite = excluded.is_favorite,
                    label = COALESCE(?, label)
                """, [comicID, page, label, on, label])
        }
    }

    func deleteBookmark(_ id: Int64) async throws {
        try await write { db in try db.run("DELETE FROM bookmarks WHERE id = ?", [id]) }
    }

    func highlights() async throws -> [Highlight] {
        try await read { db in
            try db.query("""
                SELECT b.id, b.comic_id, b.page, b.label, b.is_favorite, b.created_at, \(ComicSQL.columns)
                FROM bookmarks b JOIN comics c ON c.id = b.comic_id \(ComicSQL.joins)
                WHERE b.is_favorite = 1 AND c.deleted_at IS NULL ORDER BY b.created_at DESC
                """) { Highlight(bookmark: Self.bookmark($0), comic: ComicSQL.comic(from: $0, offset: 6)) }
        }
    }

    private static func bookmark(_ r: Row) -> Bookmark {
        Bookmark(id: r.int64(0), comicID: r.int64(1), page: r.int(2), label: r.string(3) ?? "",
                 isHighlight: r.bool(4), createdAt: r.string(5) ?? "")
    }

    // MARK: - Delete, trash, restore

    /// Soft-deletes comics. `reason` is "user" for a deliberate delete, "missing" when the file
    /// vanished. `trashedPaths` records where files went in the system Trash so Restore can move
    /// them back.
    func softDelete(_ ids: [Int64], reason: String = "user", trashedPaths: [Int64: String] = [:]) async throws {
        try await write { db in
            try db.transaction {
                for id in ids {
                    try db.run("UPDATE comics SET deleted_at = datetime('now'), deleted_reason = ?, trashed_file_path = ? WHERE id = ?",
                               [reason, trashedPaths[id], id])
                }
            }
        }
    }

    func trashedComics() async throws -> [Comic] {
        try await read { db in
            try db.query("\(ComicSQL.select) WHERE c.deleted_at IS NOT NULL ORDER BY c.deleted_at DESC") { ComicSQL.comic(from: $0) }
        }
    }

    func trashedFilePath(_ id: Int64) async throws -> String? {
        try await read { db in try db.scalarString("SELECT trashed_file_path FROM comics WHERE id = ?", [id]) }
    }

    func restore(_ ids: [Int64]) async throws {
        try await write { db in
            try db.transaction {
                for id in ids {
                    try db.run("UPDATE comics SET deleted_at = NULL, deleted_reason = NULL, trashed_file_path = NULL WHERE id = ?", [id])
                }
            }
        }
    }

    /// Permanently removes trashed rows (and their progress, tags, bookmarks, path entries).
    func purge(_ ids: [Int64]?) async throws {
        try await write { db in
            if let ids {
                try db.transaction { for id in ids { try db.run("DELETE FROM comics WHERE id = ? AND deleted_at IS NOT NULL", [id]) } }
            } else {
                try db.run("DELETE FROM comics WHERE deleted_at IS NOT NULL")
            }
        }
    }

    /// Erases the whole library database (not the comic files).
    func eraseLibrary() async throws {
        try await write { db in
            try db.transaction {
                for table in ["comic_tags", "tags", "favorites", "bookmarks", "reading_history", "reading_progress",
                              "run_items", "runs", "series_covers", "series_reader_prefs", "character_covers",
                              "series_order", "character_order", "publisher_order", "reading_order_overrides",
                              "metadata_conflicts", "comics"] {
                    try db.run("DELETE FROM \(table)")
                }
            }
        }
    }
}
