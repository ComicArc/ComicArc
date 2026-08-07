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
    /// The matched GCD series' own start year (e.g. "1963", "1999") -- GCD frequently catalogs
    /// same-named volumes (a restart, a legacy-numbering continuation) as entirely distinct
    /// series ids sharing one display name, so the series name alone can't tell them apart.
    /// Callers use this to backfill `comics.volume` when a comic has no Volume of its own (no
    /// ComicInfo.xml tag), never to overwrite an existing one.
    let matchedSeriesYearBegan: Int?
}

struct GCDSeriesBond {
    let originName: String; let originPublisher: String
    let targetName: String; let targetPublisher: String
}

/// A candidate series for the manual "Fix Match" picker -- distinct from the private `Candidate`
/// type `lookupIssue` scores internally, since this one is a plain search result meant for a
/// human to browse and choose from, not something the automatic matcher ranks.
struct GCDSeriesCandidate: Identifiable, Hashable {
    let id: Int
    let name: String
    let publisherName: String?
    let yearBegan: Int?
    let yearEnded: Int?
    let issueCount: Int
}

struct GCDIssueCandidate: Identifiable, Hashable {
    let id: Int
    let number: String
    let keyDate: String?
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
        // Deliberately not `guard let db = self.db` here: capturing the pointer before entering
        // any queue.sync block and reusing it across fetchCandidates' two separate sync calls
        // below would race reopen(), which sqlite3_close()s and reassigns db inside its own
        // queue.sync -- a capture taken beforehand can end up pointing at an already-closed
        // handle. `isAvailable` does its own synchronized read just to fail fast; the real
        // queries re-read `self.db` fresh from inside each queue.sync block instead.
        guard isAvailable, let issueNumber, !issueNumber.isEmpty else { return nil }
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
                guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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
            if let publisher, let pubName = c.publisherName {
                if Self.normalizePublisher(publisher) == Self.normalizePublisher(pubName) {
                    score += 50; hasRealSignal = true
                } else {
                    // A known publisher that actively disagrees is a real negative signal, not a
                    // neutral "no bonus" -- without this, a foreign-market reprint house (Panini
                    // France, Editorial Televisa, ...) with no `year_ended` recorded in GCD (read
                    // as "still being published" by the check below) can out-score nothing and
                    // absorb a same-named, same-numbered issue from a completely different
                    // publisher on year signal alone. Real bug found this way: a 2022 Marvel comic
                    // matched a 2007 Panini France reprint series purely because GCD never recorded
                    // when that reprint line ended.
                    score -= 20
                }
            }
            if let year, let yb = c.yearBegan {
                // GCD leaves year_ended NULL for a series still being published -- the majority
                // of what anyone is actually reading day-to-day. Falling back to `?? yb` collapsed
                // that into a single-year window and penalized every ongoing series' comic dated
                // after its first year, which is most of them.
                let ye = c.yearEnded ?? Int.max
                if year >= yb && year <= ye { score += 40; hasRealSignal = true }
                else { score -= min(30, abs(year - yb) * 2) }
            }
            score += min(c.issueCount, 100) / 10
            guard hasRealSignal, score >= 40 else { continue }
            scored.append((c, score))
        }
        guard !scored.isEmpty else { return nil }

        // Grouped into score tiers (best first) rather than one flat sorted list: two GCD series
        // sharing an identical display name (a Silver-Age original run and an unrelated modern
        // restart both just called "The Amazing Spider-Man") can tie for the exact same score
        // when there's no local `year` to tell them apart -- issue-count only breaks ties up to
        // its min(...,100) cap, so two long-running series both saturate it identically. If more
        // than one candidate in the SAME tier genuinely contains this issue number, guessing
        // between them risks silently attaching a decades-wrong cover date/volume (a 2019 comic
        // matched to a 1965 issue) -- reporting no match for that tier is safer than a confidently
        // wrong one. A tier with zero hits still falls through to the next, lower tier as before.
        let tiers = Dictionary(grouping: scored, by: \.score).sorted { $0.key > $1.key }
        for (score, pairs) in tiers {
            let hits = pairs.compactMap { pair in
                queryIssue(seriesId: pair.candidate.id, issueNumber: issueNumber).map { (pair.candidate, $0) }
            }
            guard hits.count <= 1 else { return nil }
            guard let (candidate, issueRow) = hits.first else { continue }
            let confidence = score >= 85 ? 100 : (score >= 60 ? 90 : 75)
            let reason = score >= 85
                ? "Matched to the offline comics database (publisher and year confirmed)"
                : "Matched to the offline comics database"
            return GCDIssueMatch(gcdIssueId: issueRow.id, coverDate: issueRow.keyDate, confidence: confidence, reason: reason,
                                  canonicalSeriesName: candidate.name, canonicalIssueNumber: issueRow.canonicalNumber,
                                  matchedSeriesYearBegan: candidate.yearBegan)
        }

        // Legacy-numbering continuation fallback. Some publishers keep a series' original issue
        // numbering incrementing straight through one or more volume restarts (e.g. Marvel's 2017
        // "Legacy Numbering" branding, which can sum across *several* prior relaunches, not just
        // the immediately preceding one -- Amazing Spider-Man's 1963/1999/2015/2018 chain is a real
        // example). The exact number the direct lookup above just tried won't exist in ANY
        // candidate in that case, since a "legacy 701" issue is cataloged in the matched volume's
        // own data as a small plain number. The match target still has to independently earn a
        // real-signal score (publisher/year) same as any other match -- only the chain of earlier
        // volumes (used purely to compute the cumulative numbering offset, never returned as the
        // match itself) is walked via GCD's own `series_bond` graph, not a "nearest same-named
        // series by year" heuristic -- a hop is only taken when GCD has actually recorded that
        // relationship, which is safer than assuming the nearest-by-year same-named entry is the
        // real predecessor. Every hop still requires a substantial issue count, to keep one-shots/
        // specials from being mistaken for a real preceding volume, and the walk is capped at a
        // small number of hops to bound pathological/cyclic bond data.
        if let localNumeric = Int(issueNumber) {
            for (candidate, _) in scored.sorted(by: { $0.score > $1.score }) where candidate.issueCount >= 10 {
                guard let match = matchViaLegacyChain(candidateId: candidate.id, localNumeric: localNumeric) else { continue }
                let hopWord = match.hops == 1 ? "1 earlier volume" : "\(match.hops) earlier volumes"
                return GCDIssueMatch(
                    gcdIssueId: match.row.id, coverDate: match.row.keyDate, confidence: 75,
                    reason: "Matched via legacy numbering continuing through \(hopWord)",
                    canonicalSeriesName: candidate.name, canonicalIssueNumber: issueNumber,
                    matchedSeriesYearBegan: candidate.yearBegan
                )
            }
        }
        return nil
    }

    private static let continuationBondTypes = """
        ('major_name_numbering_continues', 'minor_name_numbering_continues',
         'publisher_numbering_continues', 'subnumbering_continues')
        """

    /// The series this one's numbering continues FROM, per GCD's own bond graph (not a name/year
    /// heuristic) -- along with its issue count, so the caller can apply the same "substantial
    /// issue count" guard used everywhere else in this fallback. `LIMIT 1`: a series should have at
    /// most one real numbering-continuation predecessor; if GCD data ever has more than one such
    /// bond, taking any single one is no worse than the ambiguity already inherent in that data.
    private func bondPredecessor(of seriesId: Int) -> (id: Int, issueCount: Int)? {
        let sql = """
            SELECT sb.origin_id, s.issue_count
            FROM series_bond sb
            JOIN series_bond_type bt ON bt.id = sb.bond_type_id
            JOIN series s ON s.id = sb.origin_id
            WHERE sb.target_id = ? AND bt.name IN \(Self.continuationBondTypes)
            LIMIT 1
        """
        var stmt: OpaquePointer?
        var result: (id: Int, issueCount: Int)?
        queue.sync {
            guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(seriesId))
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = (Int(sqlite3_column_int(stmt, 0)), Int(sqlite3_column_int(stmt, 1)))
            }
        }
        return result
    }

    /// Walks backward from `candidateId` through GCD's bond graph, accumulating each predecessor's
    /// own issue extent, and retries `queryIssue` against `candidateId` at each increasing
    /// cumulative offset -- so a chain of several relaunches sums correctly instead of only ever
    /// trying the nearest one.
    private func matchViaLegacyChain(candidateId: Int, localNumeric: Int, maxHops: Int = 10) -> (row: IssueRow, hops: Int)? {
        var cumulativeExtent = 0
        var walkFrom = candidateId
        var hops = 0
        while hops < maxHops {
            guard let predecessor = bondPredecessor(of: walkFrom), predecessor.issueCount >= 10 else { return nil }
            guard let extent = maxLegacyNumber(seriesId: predecessor.id), extent > 0 else { return nil }
            cumulativeExtent += extent
            hops += 1
            let adjusted = localNumeric - cumulativeExtent
            guard adjusted > 0 else { return nil }
            if let row = queryIssue(seriesId: candidateId, issueNumber: String(adjusted)) {
                return (row, hops)
            }
            walkFrom = predecessor.id
        }
        return nil
    }

    /// The highest true/legacy issue number (parenthetical continuation number if present,
    /// otherwise the plain number) recorded anywhere in this GCD series -- used to find where a
    /// later, same-named volume's numbering picks up from.
    private func maxLegacyNumber(seriesId: Int) -> Int? {
        let sql = "SELECT number FROM issue WHERE series_id = ? AND variant_of_id IS NULL"
        var stmt: OpaquePointer?
        var maxValue: Int?
        queue.sync {
            guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(seriesId))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let raw = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                guard let value = Int(Self.trueContinuingNumber(from: raw)) else { continue }
                maxValue = max(maxValue ?? value, value)
            }
        }
        return maxValue
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

    /// Free-text series search for the manual "Fix Match" picker -- unlike `lookupIssue`'s
    /// exact-normalized-name candidate pool, this is a human browsing by whatever they type, so it
    /// matches on the raw display name with a substring `LIKE`, ranked by issue count (a real,
    /// long-running series is a much more likely intended match than an obscure one-off sharing a
    /// word). `LIKE` is case-insensitive for ASCII in SQLite by default.
    func searchSeries(query: String, limit: Int = 40) -> [GCDSeriesCandidate] {
        guard isAvailable else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let sql = """
            SELECT s.id, s.name, p.name, s.year_began, s.year_ended, s.issue_count
            FROM series s LEFT JOIN publisher p ON p.id = s.publisher_id
            WHERE s.name LIKE ?
            ORDER BY s.issue_count DESC
            LIMIT ?
        """
        var results: [GCDSeriesCandidate] = []
        var stmt: OpaquePointer?
        queue.sync {
            guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, "%\(trimmed)%", -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let pub = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let yb = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil
                let ye = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 4)) : nil
                let count = Int(sqlite3_column_int(stmt, 5))
                results.append(GCDSeriesCandidate(id: id, name: name, publisherName: pub, yearBegan: yb, yearEnded: ye, issueCount: count))
            }
        }
        return results
    }

    /// Every real (non-variant) issue in a chosen series, for the second level of the manual "Fix
    /// Match" picker -- ordered by GCD's own `sort_code` (its canonical publication order), and the
    /// displayed number is the same `trueContinuingNumber` unwrap `lookupIssue` uses, so a legacy-
    /// numbered issue like "(701)" shows its real number, not GCD's raw catalog string.
    func issuesForSeries(seriesId: Int) -> [GCDIssueCandidate] {
        guard isAvailable else { return [] }
        let sql = "SELECT id, key_date, number FROM issue WHERE series_id = ? AND variant_of_id IS NULL ORDER BY sort_code"
        var results: [GCDIssueCandidate] = []
        var stmt: OpaquePointer?
        queue.sync {
            guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(seriesId))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let dateRaw = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let date = (dateRaw?.isEmpty == false) ? dateRaw : nil
                let rawNumber = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                results.append(GCDIssueCandidate(id: id, number: Self.trueContinuingNumber(from: rawNumber), keyDate: date))
            }
        }
        return results
    }

    func allSeriesBonds() -> [GCDSeriesBond] {
        guard isAvailable else { return [] }
        let sql = """
            SELECT so.name, po.name, st.name, pt.name
            FROM series_bond sb
            JOIN series so ON so.id = sb.origin_id
            JOIN series st ON st.id = sb.target_id
            LEFT JOIN publisher po ON po.id = so.publisher_id
            LEFT JOIN publisher pt ON pt.id = st.publisher_id
            JOIN series_bond_type bt ON bt.id = sb.bond_type_id
            WHERE bt.name IN \(Self.continuationBondTypes)
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
