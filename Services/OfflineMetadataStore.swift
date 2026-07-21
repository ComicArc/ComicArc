import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct GCDIssueMatch {
    let gcdIssueId: Int
    let coverDate: String?
    let confidence: Int
    let reason: String
    /// The verified official series name and issue number, straight from the catalog —
    /// lets callers (e.g. the rename tool) suggest a correct filename even when the local
    /// series folder is an abbreviation ("ASM") or the local issue number is padded ("001").
    let canonicalSeriesName: String
    let canonicalIssueNumber: String
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

    /// Must exactly mirror the Python ETL's compute_initials. Lets a fan abbreviation like
    /// "ASM" or "USM" resolve to "Amazing Spider-Man" / "Ultimate Spider-Man" without a
    /// hand-curated alias table — most real-world comic abbreviations are literally the
    /// initials of each word (hyphenated words counted separately, "The" prefix ignored).
    static func computeInitials(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"\s*\((?:19|20)\d{2}(?:-(?:19|20)?\d{2,4})?\)\s*$"#,
                                    with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*,?\s*[Vv]ol(?:ume)?\.?\s*\d+\s*$"#,
                                    with: "", options: .regularExpression)
        if s.lowercased().hasPrefix("the ") { s = String(s.dropFirst(4)) }
        let words = s.split(whereSeparator: { $0 == " " || $0 == "-" })
        return words.compactMap { $0.first?.isLetter == true ? String($0.first!).uppercased() : nil }.joined()
    }

    /// A local series folder name is treated as a possible abbreviation only when, after
    /// stripping the trailing year/volume annotation, what's left is a single short alphabetic
    /// token — "ASM" qualifies, "Amazing Spider-Man" (with spaces) does not need this path at
    /// all since the plain name match already handles it.
    private static func abbreviationToken(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"\s*\((?:19|20)\d{2}(?:-(?:19|20)?\d{2,4})?\)\s*$"#,
                                    with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*,?\s*[Vv]ol(?:ume)?\.?\s*\d+\s*$"#,
                                    with: "", options: .regularExpression)
        guard (2...6).contains(s.count), s.allSatisfy({ $0.isLetter }) else { return nil }
        return s.uppercased()
    }

    // MARK: - Issue lookup

    /// GCD catalogs annuals/specials as their own series ("The Amazing Spider-Man Annual"),
    /// separate from the ongoing title, even when a local library files them in the same
    /// folder. When the comic's own type suggests this, search that companion series name
    /// first — falling back to the plain series name only if nothing turns up there.
    private static func gcdTypeSuffix(for type: ComicType) -> String? {
        switch type {
        case .annual: return "annual"
        case .special: return "special"
        case .giantSize, .kingSize: return "giant size"
        default: return nil
        }
    }

    /// Conservative by design: returns nil rather than guess when there isn't a real signal
    /// (publisher match or year match) backing the chosen series candidate — a wrong match
    /// silently mis-files a comic, which is worse than no match at all.
    func lookupIssue(series: String, publisher: String?, issueNumber: String?, year: Int?,
                      comicType: ComicType = .regular) -> GCDIssueMatch? {
        guard let db, let issueNumber, !issueNumber.isEmpty else { return nil }
        let normSeries = Self.normalizeSeriesName(series)
        guard !normSeries.isEmpty else { return nil }

        struct Candidate { let id: Int; let name: String; let publisherName: String?; let yearBegan: Int?; let yearEnded: Int?; let issueCount: Int }
        func fetchCandidates(column: String, value: String) -> [Candidate] {
            var results: [Candidate] = []
            let sql = """
                SELECT s.id, s.name, p.name, s.year_began, s.year_ended, s.issue_count
                FROM series s LEFT JOIN publisher p ON p.id = s.publisher_id
                WHERE s.\(column) = ?
            """
            var stmt: OpaquePointer?
            queue.sync {
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                sqlite3_bind_text(stmt, 1, value, -1, SQLITE_TRANSIENT)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = Int(sqlite3_column_int(stmt, 0))
                    let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let pub = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                    let yb = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil
                    let ye = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 4)) : nil
                    let count = Int(sqlite3_column_int(stmt, 5))
                    results.append(Candidate(id: id, name: name, publisherName: pub, yearBegan: yb, yearEnded: ye, issueCount: count))
                }
                sqlite3_finalize(stmt)
            }
            return results
        }

        let abbrev = Self.abbreviationToken(series)

        func candidatePool(nameSuffix: String?) -> [Candidate] {
            let name = nameSuffix.map { "\(normSeries) \($0)" } ?? normSeries
            var pool = fetchCandidates(column: "norm_name", value: name)
            if let abbrev {
                let initials = nameSuffix.flatMap { $0.first.map { c in abbrev + String(c).uppercased() } } ?? abbrev
                let existingIds = Set(pool.map(\.id))
                pool += fetchCandidates(column: "initials", value: initials).filter { !existingIds.contains($0.id) }
            }
            return pool
        }

        var candidates = candidatePool(nameSuffix: nil)
        if let suffix = Self.gcdTypeSuffix(for: comicType) {
            let variantCandidates = candidatePool(nameSuffix: suffix)
            if !variantCandidates.isEmpty { candidates = variantCandidates }
        }
        guard !candidates.isEmpty else { return nil }

        var scored: [(candidate: Candidate, score: Int)] = []
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
            guard hasRealSignal, score >= 40 else { continue } // no real corroboration — skip
            scored.append((c, score))
        }
        guard !scored.isEmpty else { return nil }

        // A single title is often split across several GCD series entries (relaunches,
        // restart-numbered "Annual" lines with the true continuing number in parens like
        // "1 (35)", etc.) — the highest-scoring candidate isn't necessarily the one that
        // actually contains this specific issue, so try each in score order rather than
        // committing to just the top one.
        for (candidate, score) in scored.sorted(by: { $0.score > $1.score }) {
            guard let issueRow = queryIssue(seriesId: candidate.id, issueNumber: issueNumber) else { continue }
            let confidence = score >= 85 ? 100 : (score >= 60 ? 90 : 75)
            let reason = score >= 85
                ? "Matched to the offline comics database (publisher and year confirmed)"
                : "Matched to the offline comics database"
            return GCDIssueMatch(gcdIssueId: issueRow.id, coverDate: issueRow.keyDate, confidence: confidence, reason: reason,
                                  canonicalSeriesName: candidate.name, canonicalIssueNumber: issueRow.canonicalNumber)
        }
        return nil
    }

    private struct IssueRow { let id: Int; let keyDate: String?; let canonicalNumber: String }

    private func queryIssue(seriesId: Int, issueNumber: String) -> IssueRow? {
        // Three tiers, tried in order: (1) exact string match — handles non-numeric labels
        // like "Alpha" correctly; (2) a numeric comparison so "001" (a common local
        // zero-padding convention) still finds GCD's "1"; (3) GCD's restart-numbering
        // convention, where a relaunched "Annual" line stores e.g. "1 (35)" — the true
        // continuing number in parentheses after a reset display number. Tiers 2 and 3 only
        // fire when the requested number actually parses as numeric, so neither can misfire
        // on an unrelated non-numeric label.
        let sql = """
            SELECT id, key_date, number, 0 AS rank, sort_code FROM issue
            WHERE series_id = ? AND number = ? AND variant_of_id IS NULL
            UNION ALL
            SELECT id, key_date, number, 1 AS rank, sort_code FROM issue
            WHERE series_id = ? AND variant_of_id IS NULL
                  AND ? IS NOT NULL AND CAST(number AS REAL) = ?
            UNION ALL
            SELECT id, key_date, number, 2 AS rank, sort_code FROM issue
            WHERE series_id = ? AND variant_of_id IS NULL
                  AND ? IS NOT NULL AND number LIKE '%(' || ? || ')'
            ORDER BY rank, sort_code LIMIT 1
        """
        var result: IssueRow?
        var stmt: OpaquePointer?
        let numericValue = Double(issueNumber)
        let parenValue = numericValue.map { $0 == $0.rounded() ? String(Int($0)) : issueNumber }
        queue.sync {
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, Int32(seriesId))
            sqlite3_bind_text(stmt, 2, issueNumber, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(seriesId))
            if let numericValue {
                sqlite3_bind_double(stmt, 4, numericValue)
                sqlite3_bind_double(stmt, 5, numericValue)
            } else {
                sqlite3_bind_null(stmt, 4)
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_int(stmt, 6, Int32(seriesId))
            if let parenValue {
                sqlite3_bind_text(stmt, 7, parenValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 8, parenValue, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 7)
                sqlite3_bind_null(stmt, 8)
            }
            if sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let dateRaw = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let date = (dateRaw?.isEmpty == false) ? dateRaw : nil
                let rawNumber = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? issueNumber
                result = IssueRow(id: id, keyDate: date, canonicalNumber: Self.trueContinuingNumber(from: rawNumber))
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    /// GCD stores restart-numbered issues as e.g. "1 (35)" — the parenthetical is the real
    /// continuing number readers actually care about, so prefer it when present.
    private static func trueContinuingNumber(from rawNumber: String) -> String {
        if let openParen = rawNumber.firstIndex(of: "("), let closeParen = rawNumber.firstIndex(of: ")"), openParen < closeParen {
            return String(rawNumber[rawNumber.index(after: openParen)..<closeParen])
        }
        return rawNumber
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
