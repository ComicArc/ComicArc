import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct GCDIssueMatch {
    let gcdIssueId: Int
    let coverDate: String?
    let confidence: Int
    let reason: String
}

struct GCDSeriesBond {
    let originName: String; let originPublisher: String
    let targetName: String; let targetPublisher: String
}

/// Read-only client for the offline comics reference database (downloaded once during setup,
/// built from the Grand Comics Database's public data dump — see the ETL pipeline notes).
/// Every lookup here is local; nothing about this ever makes a network call at runtime. A
/// missing or not-yet-downloaded database is a completely normal state: every method returns
/// nil/empty and callers fall back to today's filename/date-inference behavior.
final class OfflineMetadataStore {
    static let shared = OfflineMetadataStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.comicarc.offlinemetadata")

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ComicArc/gcd_lookup.sqlite")
    }

    private let overridePath: String?
    private var path: String { overridePath ?? Self.fileURL.path }

    var isAvailable: Bool { queue.sync { db != nil } }

    var fileSizeOnDisk: Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
    }

    convenience init() { self.init(path: nil) }

    /// `path` overrides the real Application Support location — used by tests to point at a
    /// small fixture database instead of the real downloaded one.
    init(path: String?) {
        overridePath = path
        reopen()
    }

    /// Call after a fresh download completes, so the running app picks it up without a relaunch.
    func reopen() {
        queue.sync {
            if db != nil { sqlite3_close(db); db = nil }
            guard FileManager.default.fileExists(atPath: path) else { return }
            if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                db = nil
            }
        }
    }

    func deleteDownloadedDatabase() {
        queue.sync {
            if db != nil { sqlite3_close(db); db = nil }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Normalization (must exactly mirror the Python ETL's normalize_series_name)

    static func normalizeSeriesName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"\s*\((?:19|20)\d{2}(?:-(?:19|20)?\d{2,4})?\)\s*$"#,
                                    with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*,?\s*[Vv]ol(?:ume)?\.?\s*\d+\s*$"#,
                                    with: "", options: .regularExpression)
        s = s.lowercased()
        if s.hasPrefix("the ") { s = String(s.dropFirst(4)) }
        s = s.replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func normalizePublisher(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }

    // MARK: - Issue lookup

    /// Conservative by design: returns nil rather than guess when there isn't a real signal
    /// (publisher match or year match) backing the chosen series candidate — a wrong match
    /// silently mis-files a comic, which is worse than no match at all.
    func lookupIssue(series: String, publisher: String?, issueNumber: String?, year: Int?) -> GCDIssueMatch? {
        guard let db, let issueNumber, !issueNumber.isEmpty else { return nil }
        let normSeries = Self.normalizeSeriesName(series)
        guard !normSeries.isEmpty else { return nil }

        struct Candidate { let id: Int; let publisherName: String?; let yearBegan: Int?; let yearEnded: Int?; let issueCount: Int }
        var candidates: [Candidate] = []
        let sql = """
            SELECT s.id, p.name, s.year_began, s.year_ended, s.issue_count
            FROM series s LEFT JOIN publisher p ON p.id = s.publisher_id
            WHERE s.norm_name = ?
        """
        var stmt: OpaquePointer?
        queue.sync {
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, normSeries, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let pub = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let yb = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 2)) : nil
                let ye = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil
                let count = Int(sqlite3_column_int(stmt, 4))
                candidates.append(Candidate(id: id, publisherName: pub, yearBegan: yb, yearEnded: ye, issueCount: count))
            }
            sqlite3_finalize(stmt)
        }
        guard !candidates.isEmpty else { return nil }

        var best: (candidate: Candidate, score: Int)?
        for c in candidates {
            var score = 0
            var hasRealSignal = false
            if let publisher, let pubName = c.publisherName,
               Self.normalizePublisher(publisher) == Self.normalizePublisher(pubName) {
                score += 50; hasRealSignal = true
            }
            if let year, let yb = c.yearBegan {
                let ye = c.yearEnded ?? yb
                if year >= yb && year <= ye { score += 40; hasRealSignal = true }
                else { score -= min(30, abs(year - yb) * 2) }
            }
            score += min(c.issueCount, 100) / 10
            guard hasRealSignal else { continue } // no publisher or year corroboration at all — skip
            if best == nil || score > best!.score { best = (c, score) }
        }
        guard let match = best, match.score >= 40 else { return nil }

        guard let issueRow = queryIssue(seriesId: match.candidate.id, issueNumber: issueNumber) else { return nil }
        let confidence = match.score >= 85 ? 100 : (match.score >= 60 ? 90 : 75)
        let reason = match.score >= 85
            ? "Matched to the offline comics database (publisher and year confirmed)"
            : "Matched to the offline comics database"
        return GCDIssueMatch(gcdIssueId: issueRow.id, coverDate: issueRow.keyDate, confidence: confidence, reason: reason)
    }

    private struct IssueRow { let id: Int; let keyDate: String? }

    private func queryIssue(seriesId: Int, issueNumber: String) -> IssueRow? {
        let sql = """
            SELECT id, key_date FROM issue
            WHERE series_id = ? AND number = ? AND variant_of_id IS NULL
            ORDER BY sort_code LIMIT 1
        """
        var result: IssueRow?
        var stmt: OpaquePointer?
        queue.sync {
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, Int32(seriesId))
            sqlite3_bind_text(stmt, 2, issueNumber, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let dateRaw = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let date = (dateRaw?.isEmpty == false) ? dateRaw : nil
                result = IssueRow(id: id, keyDate: date)
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    // MARK: - Series continuation bonds (feeds automatic Series Links)

    /// All known real-world series continuations from the offline database, resolved to plain
    /// names/publishers rather than internal GCD ids — the caller matches these against the
    /// user's own library by name, since GCD's ids mean nothing to ComicArc's own schema.
    func allSeriesBonds() -> [GCDSeriesBond] {
        guard db != nil else { return [] }
        let sql = """
            SELECT so.name, po.name, st.name, pt.name
            FROM series_bond sb
            JOIN series so ON so.id = sb.origin_id
            JOIN series st ON st.id = sb.target_id
            LEFT JOIN publisher po ON po.id = so.publisher_id
            LEFT JOIN publisher pt ON pt.id = st.publisher_id
            JOIN series_bond_type bt ON bt.id = sb.bond_type_id
            WHERE bt.name IN ('major_name_numbering_continues', 'minor_name_numbering_continues',
                               'publisher_numbering_continues', 'subnumbering_continues')
        """
        var results: [GCDSeriesBond] = []
        var stmt: OpaquePointer?
        queue.sync {
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let originName = sqlite3_column_text(stmt, 0), let targetName = sqlite3_column_text(stmt, 2) else { continue }
                let originPub = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "Unknown"
                let targetPub = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "Unknown"
                results.append(GCDSeriesBond(originName: String(cString: originName), originPublisher: originPub,
                                              targetName: String(cString: targetName), targetPublisher: targetPub))
            }
            sqlite3_finalize(stmt)
        }
        return results
    }
}
