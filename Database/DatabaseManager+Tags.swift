import Foundation
import SQLite3

extension DatabaseManager {
    /// Batch tag lookup for a set of comic ids -- one query instead of N, since the taste-based
    /// recommendation feed calls this with every unread, different-series candidate at once
    /// (potentially the whole library), and looping `tags(for:)` per comic would be a real N+1
    /// pattern at that scale. Chunked like every other unbounded id array, since a large library's
    /// candidate set can comfortably exceed SQLite's bound-parameter ceiling.
    func tagIdsByComic(_ comicIds: [Int64]) -> [Int64: Set<Int64>] {
        guard !comicIds.isEmpty else { return [:] }
        return queue.sync {
            var result: [Int64: Set<Int64>] = [:]
            for chunk in idChunks(comicIds) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                rows("SELECT comic_id, tag_id FROM comic_tags WHERE comic_id IN (\(placeholders))",
                     args: chunk) { s in (colInt64(s, 0), colInt64(s, 1)) }
                    .forEach { comicId, tagId in result[comicId, default: []].insert(tagId) }
            }
            return result
        }
    }

    func tags(for comicId: Int64) -> [Tag] {
        queue.sync {
            rows("SELECT t.id, t.name, t.category FROM tags t JOIN comic_tags ct ON t.id = ct.tag_id WHERE ct.comic_id = ? ORDER BY t.name",
                 args: [comicId]) { Tag(id: colInt64($0, 0), name: colText($0, 1) ?? "", category: colText($0, 2)) }
        }
    }

    func addTag(name: String, to comicId: Int64, category: TagCategory = .custom) {
        queue.sync {
            _ = run("INSERT OR IGNORE INTO tags (name, category) VALUES (?,?)", args: [name, category.rawValue])
            let resolvedId = scalarInt("SELECT id FROM tags WHERE name = ?", args: [name])
            guard resolvedId > 0 else { return }
            _ = run("INSERT OR IGNORE INTO comic_tags (comic_id, tag_id) VALUES (?,?)",
                    args: [comicId, Int64(resolvedId)])
        }
    }

    func removeTag(tagId: Int64, from comicId: Int64) {
        queue.sync {
            _ = run("DELETE FROM comic_tags WHERE comic_id = ? AND tag_id = ?", args: [comicId, tagId])
            _ = run("DELETE FROM tags WHERE id = ? AND (SELECT COUNT(*) FROM comic_tags WHERE tag_id = ?) = 0",
                    args: [tagId, tagId])
        }
    }

    func allTags() -> [(tag: Tag, count: Int)] {
        queue.sync {
            rows("""
                SELECT t.id, t.name, t.category, COUNT(ct.comic_id) as cnt
                FROM tags t JOIN comic_tags ct ON t.id = ct.tag_id
                JOIN comics c ON ct.comic_id = c.id
                WHERE c.deleted_at IS NULL
                GROUP BY t.id ORDER BY cnt DESC, t.name
            """) { (Tag(id: colInt64($0, 0), name: colText($0, 1) ?? "", category: colText($0, 2)), colInt($0, 3)) }
        }
    }

    /// Renames a tag across the whole library. `tags.name` is UNIQUE, so if `newName` already
    /// belongs to a different tag, this merges into it instead of erroring: every comic tagged
    /// with either ends up tagged with just the target, and the old tag row is removed.
    func renameTag(id: Int64, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.sync {
            let existingId = scalarInt("SELECT id FROM tags WHERE name = ? AND id != ?", args: [trimmed, id])
            if existingId > 0 {
                inTransaction {
                    // Repoint every comic_tags row from the old tag to the target tag; a row
                    // that would collide with the target's own PRIMARY KEY (comic_id, tag_id) --
                    // i.e. a comic already wearing both tags -- is left alone here and cleaned
                    // up by the cascade below instead of erroring the whole rename.
                    guard run("UPDATE OR IGNORE comic_tags SET tag_id = ? WHERE tag_id = ?",
                              args: [Int64(existingId), id]) != -1 else { return false }
                    guard run("DELETE FROM tags WHERE id = ?", args: [id]) != -1 else { return false }
                    return true
                }
            } else {
                _ = run("UPDATE tags SET name = ? WHERE id = ?", args: [trimmed, id])
            }
        }
    }

    /// Removes a tag from the entire library (every comic that had it), not just one comic --
    /// `comic_tags.tag_id` cascades, so this is the one statement that needs to run.
    func deleteTagGlobally(id: Int64) {
        queue.sync { _ = run("DELETE FROM tags WHERE id = ?", args: [id]) }
    }

    func setTagCategory(id: Int64, category: TagCategory) {
        queue.sync { _ = run("UPDATE tags SET category = ? WHERE id = ?", args: [category.rawValue, id]) }
    }

}
