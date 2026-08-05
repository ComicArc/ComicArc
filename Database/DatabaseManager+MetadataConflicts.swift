import Foundation
import SQLite3

extension DatabaseManager {
    struct MetadataConflictInput {
        let comicId: Int64
        let field: String   // "series" | "publisher" | "issue_number"
        let current: String?
        let proposed: String?
        let source: String
    }

    /// Re-detecting the same (comic, field) conflict updates the existing row and resets it to
    /// 'pending' -- a stale dismissal must not permanently hide a disagreement that's still real
    /// (and possibly changed) on a later pass.
    func upsertMetadataConflicts(_ items: [MetadataConflictInput]) {
        guard !items.isEmpty else { return }
        _ = queue.sync {
            inTransaction {
                runBatch("""
                    INSERT INTO metadata_conflicts (comic_id, field, current_value, proposed_value, proposed_source)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(comic_id, field) DO UPDATE SET
                        current_value = excluded.current_value,
                        proposed_value = excluded.proposed_value,
                        proposed_source = excluded.proposed_source,
                        status = 'pending',
                        resolved_at = NULL
                    """, rows: items.map { [$0.comicId, $0.field, $0.current, $0.proposed, $0.source] })
            }
        }
    }

    func pendingMetadataConflicts() -> [(conflict: MetadataConflict, comic: Comic)] {
        queue.sync {
            struct Raw {
                let id: Int64; let comicId: Int64; let field: String
                let current: String?; let proposed: String?; let source: String
                let detectedAt: String; let status: String
            }
            let conflicts: [Raw] = rows("""
                SELECT mc.id, mc.comic_id, mc.field, mc.current_value, mc.proposed_value,
                       mc.proposed_source, mc.detected_at, mc.status
                FROM metadata_conflicts mc
                JOIN comics c ON c.id = mc.comic_id
                WHERE mc.status = 'pending' AND c.deleted_at IS NULL
                ORDER BY mc.detected_at DESC
                """) { s in
                Raw(id: colInt64(s, 0), comicId: colInt64(s, 1), field: colText(s, 2) ?? "",
                    current: colText(s, 3), proposed: colText(s, 4), source: colText(s, 5) ?? "",
                    detectedAt: colText(s, 6) ?? "", status: colText(s, 7) ?? "pending")
            }
            guard !conflicts.isEmpty else { return [] }
            let comicIds = Array(Set(conflicts.map(\.comicId)))
            let comics: [Comic] = idChunks(comicIds).flatMap { chunk -> [Comic] in
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                return rows("\(comicSelect) WHERE c.id IN (\(placeholders))",
                            args: chunk.map { $0 as Any? }, map: comicRow)
            }
            let comicsById = Dictionary(uniqueKeysWithValues: comics.map { ($0.id, $0) })
            return conflicts.compactMap { r in
                guard let comic = comicsById[r.comicId] else { return nil }
                return (MetadataConflict(id: r.id, comicId: r.comicId, field: r.field, currentValue: r.current,
                                          proposedValue: r.proposed, proposedSource: r.source,
                                          detectedAt: r.detectedAt, status: r.status), comic)
            }
        }
    }

    /// `apply`: writes the proposed value to `comics` and marks `meta_edited = 1` -- applying a
    /// conflict is itself a deliberate user choice, so it earns the same protection any other
    /// manual correction gets. `dismiss`: only updates the conflict's own status; `comics` is
    /// untouched, the current value stands.
    func resolveMetadataConflict(id: Int64, apply: Bool) {
        queue.sync {
            guard let row = rows("SELECT comic_id, field, proposed_value FROM metadata_conflicts WHERE id = ?",
                                  args: [id], map: { s in
                (colInt64(s, 0), colText(s, 1) ?? "", colText(s, 2))
            }).first else { return }
            let (comicId, field, proposed) = row
            if apply {
                let columns = ["series": "series", "publisher": "publisher", "issue_number": "issue_number"]
                guard let column = columns[field] else { return }
                _ = run("UPDATE comics SET \(column) = ?, meta_edited = 1 WHERE id = ?", args: [proposed, comicId])
                _ = run("UPDATE metadata_conflicts SET status = 'applied', resolved_at = CURRENT_TIMESTAMP WHERE id = ?", args: [id])
            } else {
                _ = run("UPDATE metadata_conflicts SET status = 'dismissed', resolved_at = CURRENT_TIMESTAMP WHERE id = ?", args: [id])
            }
        }
    }

    // MARK: - Existing-library import-priority audit (one-time, post-upgrade)

    static let importPriorityAuditMigrationName = "importPriorityAuditV1"

    func hasCompletedImportPriorityAudit() -> Bool {
        queue.sync { scalarInt("SELECT COUNT(*) FROM migrations WHERE name = ?", args: [Self.importPriorityAuditMigrationName]) > 0 }
    }

    func markImportPriorityAuditComplete() {
        queue.sync { _ = run("INSERT OR IGNORE INTO migrations (name) VALUES (?)", args: [Self.importPriorityAuditMigrationName]) }
    }

    /// Rows that predate the raw-fact mirror columns (added well after `has_comicinfo` already
    /// existed) -- these are exactly the comics whose series/publisher were decided under the old
    /// folder/filename-first priority, with no record of what their own ComicInfo.xml said.
    func pendingImportPriorityAuditPaths() -> [(id: Int64, path: String)] {
        queue.sync {
            rows("SELECT id, file_path FROM comics WHERE has_comicinfo = 1 AND comicinfo_series IS NULL AND deleted_at IS NULL")
                { (colInt64($0, 0), colText($0, 1) ?? "") }
        }
    }

    struct IdentitySnapshot { let series: String?; let publisher: String?; let metaEdited: Bool }

    func identitySnapshots(for ids: [Int64]) -> [Int64: IdentitySnapshot] {
        guard !ids.isEmpty else { return [:] }
        return queue.sync {
            var result: [Int64: IdentitySnapshot] = [:]
            for chunk in idChunks(ids) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                rows(
                    "SELECT id, series, publisher, meta_edited FROM comics WHERE id IN (\(placeholders))",
                    args: chunk.map { $0 as Any? }
                ) { s in
                    (colInt64(s, 0), IdentitySnapshot(series: colText(s, 1), publisher: colText(s, 2), metaEdited: colInt(s, 3) != 0))
                }.forEach { result[$0.0] = $0.1 }
            }
            return result
        }
    }

    func updateComicInfoMirrors(_ items: [(id: Int64, comicInfoSeries: String?, comicInfoPublisher: String?)]) {
        guard !items.isEmpty else { return }
        _ = queue.sync {
            inTransaction {
                runBatch("UPDATE comics SET comicinfo_series = ?, comicinfo_publisher = ? WHERE id = ?",
                         rows: items.map { [$0.comicInfoSeries, $0.comicInfoPublisher, $0.id] })
            }
        }
    }

}
