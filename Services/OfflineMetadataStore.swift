import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct GCDIssueMatch {
    let gcdIssueId: Int
    let coverDate: String?
    let confidence: Int
    let reason: String
    let canonicalSeriesName: String
    let canonicalIssueNumber: String
}

struct GCDSeriesBond {
    let originName: String; let originPublisher: String
    let targetName: String; let targetPublisher: String
}

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

    init(path: String?) {
        overridePath = path
        reopen()
    }

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

    static func normalizePublisher(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }

    static func seriesNamesMatch(local: String, gcdName: String) -> Bool {
        let normLocal = normalizeSeriesName(local)
        let normGCD = normalizeSeriesName(gcdName)
        if !normLocal.isEmpty, normLocal == normGCD { return true }
        if let abbrev = abbreviationToken(local), computeInitials(gcdName) == abbrev { return true }
        return false
    }

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

    static func abbreviationToken(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*,?\s*[Vv]ol(?:ume)?\.?\s*\d+\s*$"#,
                                    with: "", options: .regularExpression)
        guard (2...6).contains(s.count), s.allSatisfy({ $0.isLetter }) else { return nil }
        return s.uppercased()
    }

    private static func gcdTypeSuffix(for type: ComicType) -> String? {
        switch type {
        case .annual: return "annual"
        case .special: return "special"
        case .giantSize, .kingSize: return "giant size"
        default: return nil
        }
    }

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
            guard hasRealSignal, score >= 40 else { continue }
            scored.append((c, score))
        }
        guard !scored.isEmpty else { return nil }

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

    private static func trueContinuingNumber(from rawNumber: String) -> String {
        if let openParen = rawNumber.firstIndex(of: "("), let closeParen = rawNumber.firstIndex(of: ")"), openParen < closeParen {
            return String(rawNumber[rawNumber.index(after: openParen)..<closeParen])
        }
        return rawNumber
    }

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
