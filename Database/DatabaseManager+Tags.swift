import Foundation
import SQLite3

extension DatabaseManager {
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

    /// Renames a tag; if `newName` already exists, merges into that tag instead.
    func renameTag(id: Int64, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.sync {
            let existingId = scalarInt("SELECT id FROM tags WHERE name = ? AND id != ?", args: [trimmed, id])
            if existingId > 0 {
                inTransaction {
                    // Rows that would collide (comic already has both tags) are left for the
                    // cascade below.
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

    func deleteTagGlobally(id: Int64) {
        queue.sync { _ = run("DELETE FROM tags WHERE id = ?", args: [id]) }
    }

    func setTagCategory(id: Int64, category: TagCategory) {
        queue.sync { _ = run("UPDATE tags SET category = ? WHERE id = ?", args: [category.rawValue, id]) }
    }

}
