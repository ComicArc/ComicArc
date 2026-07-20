import Foundation

// MARK: - Comic type classification

// Broader than ComicSortClassifier's binary special/mainline split — this exists to feed the
// ReadingOrderEngine's placement tiers below, which need to know not just "is this special"
// but "what kind," since date-interpolation, story-arc adjacency, and the always-last safety
// net all key off the specific type. ComicSortClassifier stays as the source of truth for
// "does this sort after mainline issues at all" (used throughout the DB layer); this is a
// finer-grained classification used only by the new engine.
enum ComicType: Equatable {
    case regular
    case annual
    case oneShot
    case special
    case giantSize
    case kingSize
    case alpha
    case omega
    case issueZero
    case pointIssue      // any "#N.M" decimal that isn't otherwise classified
    case directorsCut
    case preview
    case fcbd            // Free Comic Book Day
    case ashcan
    case holidaySpecial
    // Format-only types: real comics, but not part of an ongoing issue-number sequence, so
    // the engine classifies them without ever trying to interpolate a position for them.
    case tradePaperback
    case hardcover
    case omnibus
    case graphicNovel
    case compendium

    /// True for anything the engine should try to interpolate into a series' reading order —
    /// false for regular issues (already positioned by legacy number) and format-only types
    /// (a TPB collecting issues #1-6 isn't itself "issue #3.5", it doesn't have a slot to guess).
    var needsPlacement: Bool {
        switch self {
        case .regular, .tradePaperback, .hardcover, .omnibus, .graphicNovel, .compendium:
            return false
        default:
            return true
        }
    }
}

// MARK: - Reading Order Engine

// Pure logic, no DB or SwiftUI dependency — this is what makes it unit-testable against plain
// input structs instead of a live database. DatabaseManager.recomputeReadingOrder() is the only
// caller; it fetches comics, builds ReadingOrderInput values, calls computeSeriesPositions(),
// and writes the results back to comics.reading_order_position/confidence/reason.
enum ReadingOrderEngine {

    // MARK: Classification

    private static let formatKeywords: [(String, ComicType)] = [
        ("OMNIBUS", .omnibus), ("COMPENDIUM", .compendium),
        ("HARDCOVER", .hardcover), (" HC", .hardcover),
        ("GRAPHIC NOVEL", .graphicNovel), ("TPB", .tradePaperback), ("TRADE PAPERBACK", .tradePaperback),
    ]

    // Ordered most-specific-first: "GIANT-SIZE ANNUAL" should classify as annual (the rarer,
    // more meaningful label) not giant-size, so annual/one-shot/special are checked before the
    // format-flavor keywords that often appear alongside them.
    private static let typeKeywords: [(String, ComicType)] = [
        ("FCBD", .fcbd), ("FREE COMIC BOOK DAY", .fcbd),
        ("ASHCAN", .ashcan),
        ("ANNUAL", .annual),
        ("ONE-SHOT", .oneShot), ("ONESHOT", .oneShot), ("ONE SHOT", .oneShot),
        ("HOLIDAY", .holidaySpecial),
        ("DIRECTOR'S CUT", .directorsCut), ("DIRECTORS CUT", .directorsCut),
        ("PREVIEW", .preview),
        ("GIANT-SIZE", .giantSize), ("GIANT SIZE", .giantSize),
        ("KING-SIZE", .kingSize), ("KING SIZE", .kingSize),
        ("SPECIAL", .special),
    ]

    /// Classifies a comic's type from its parsed issue number, title, and series — the same
    /// three fields ComicSortClassifier.isSpecialIssue already uses, kept consistent with it
    /// rather than introducing a second, possibly-disagreeing heuristic.
    static func classify(issueNumber: String?, title: String, series: String) -> ComicType {
        let haystack = [issueNumber ?? "", title, series].joined(separator: " ").uppercased()

        for (keyword, type) in typeKeywords where haystack.contains(keyword) {
            return type
        }
        for (keyword, type) in formatKeywords where haystack.contains(keyword) {
            return type
        }

        // Not keyword-classified — check whether the issue number itself signals a type:
        // Alpha/Omega crossover-event labels, "#0", or a "#N.M" point issue.
        let trimmed = (issueNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed == "ALPHA" { return .alpha }
        if trimmed == "OMEGA" { return .omega }
        if let num = parseLegacyNumber(issueNumber) {
            if num == 0 { return .issueZero }
            if num != num.rounded(.towardZero) { return .pointIssue }
        }
        return .regular
    }

    /// Parses a legacy/issue number into a comparable Double, handling decimals ("12.1") and
    /// returning nil for non-numeric labels (Alpha/Omega/etc. — those are typed, not numbered).
    static func parseLegacyNumber(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }

    // MARK: Positioning

    struct ReadingOrderInput {
        let id: Int64
        let groupKey: String          // publisher + (seriesGroup ?? series)
        let legacyNumber: Double?
        let comicType: ComicType
        let year: Int?
        let month: Int?
        let day: Int?
        let storyArc: String?
        let title: String             // used only for the deterministic sequence tiebreak
    }

    struct ReadingOrderResult {
        let position: Int
        let confidence: Int
        let reason: String
    }

    // Mainline positions are spaced 100_000 apart (via a *10 "tenths" scale first, so decimal
    // point issues like #12.1 get their own slot too) — this is the headroom every placement
    // tier below interpolates within. See the plan doc for the exact arithmetic; the short
    // version: #12 -> 12_000_000, #12.1 -> 12_100_000, #13 -> 13_000_000, leaving 100,000 of
    // room between any two adjacent mainline slots for repeated bisection.
    static let mainlineStride = 100_000
    static let alwaysLastBand = 10_000_000_000

    private static func mainlinePosition(for legacyNumber: Double) -> Int {
        let tenths = Int((legacyNumber * 10).rounded())
        return tenths * mainlineStride
    }

    private static func dateKey(year: Int, month: Int, day: Int?) -> Int {
        year * 10000 + month * 100 + (day ?? 15)
    }

    /// Computes a reading-order position for every comic in `inputs`, grouped internally by
    /// `groupKey`. Regular issues (and format-only types) are positioned directly by legacy
    /// number; everything with `comicType.needsPlacement == true` goes through the tiered
    /// fallback described in the plan (date interpolation -> single-date anchor -> story-arc
    /// adjacency -> proportional spread -> always-last safety net).
    static func computeSeriesPositions(_ inputs: [ReadingOrderInput]) -> [Int64: ReadingOrderResult] {
        var results: [Int64: ReadingOrderResult] = [:]

        for (_, group) in Dictionary(grouping: inputs, by: \.groupKey) {
            // Mainline: positioned directly, always — this is the stable backbone every
            // special-placement tier below interpolates against.
            var mainline: [(input: ReadingOrderInput, position: Int)] = []
            for input in group where !input.comicType.needsPlacement {
                guard let num = input.legacyNumber else { continue }
                let pos = mainlinePosition(for: num)
                mainline.append((input, pos))
                results[input.id] = ReadingOrderResult(
                    position: pos, confidence: 100,
                    reason: "Legacy issue number #\(formatNumber(num))"
                )
            }
            mainline.sort { $0.position < $1.position }

            let mainlineDated = mainline.filter { $0.input.year != nil && $0.input.month != nil }
                .sorted { dateKey(year: $0.input.year!, month: $0.input.month!, day: $0.input.day) <
                          dateKey(year: $1.input.year!, month: $1.input.month!, day: $1.input.day) }

            let specials = group.filter { $0.comicType.needsPlacement }
            var placedIds = Set<Int64>()

            // Tier 1 + 2: date-based placement (2 anchors = interpolate, 1 anchor = adjacent)
            for special in specials {
                guard let sy = special.year, let sm = special.month else { continue }
                let specialKey = dateKey(year: sy, month: sm, day: special.day)

                let afterIdx = mainlineDated.firstIndex {
                    dateKey(year: $0.input.year!, month: $0.input.month!, day: $0.input.day) > specialKey
                }

                if let afterIdx, afterIdx > 0 {
                    // Tier 1: two real anchors bracket it — interpolate the midpoint.
                    let before = mainlineDated[afterIdx - 1]
                    let after  = mainlineDated[afterIdx]
                    guard after.position - before.position > 1 else { continue }
                    let pos = before.position + (after.position - before.position) / 2
                    results[special.id] = ReadingOrderResult(
                        position: pos, confidence: 100,
                        reason: "Cover date places it between \(before.input.title.isEmpty ? "the previous" : before.input.title) and \(after.input.title.isEmpty ? "the next" : after.input.title) issue"
                    )
                    placedIds.insert(special.id)
                } else if mainlineDated.count == 1 {
                    // Tier 2: exactly one dated mainline neighbor — place immediately before
                    // or after it by date comparison rather than discarding the date entirely.
                    let only = mainlineDated[0]
                    let onlyKey = dateKey(year: only.input.year!, month: only.input.month!, day: only.input.day)
                    let pos = specialKey < onlyKey ? only.position - 1 : only.position + 1
                    results[special.id] = ReadingOrderResult(
                        position: pos, confidence: 85,
                        reason: "Cover date places it \(specialKey < onlyKey ? "before" : "after") \(only.input.title.isEmpty ? "the only dated issue in this series" : only.input.title) (only one dated neighbor available)"
                    )
                    placedIds.insert(special.id)
                }
            }

            // Tier 3: story-arc adjacency — special's StoryArc matches a mainline issue's own
            // StoryArc within this group (arc names aren't globally unique, but matching is
            // safe once already scoped to one series/seriesGroup).
            for special in specials where !placedIds.contains(special.id) {
                guard let arc = special.storyArc, !arc.isEmpty else { continue }
                guard let match = mainline.first(where: { $0.input.storyArc == arc }) else { continue }
                results[special.id] = ReadingOrderResult(
                    position: match.position + 1, confidence: 85,
                    reason: "Shares story arc \"\(arc)\" with \(match.input.title.isEmpty ? "a mainline issue" : match.input.title)"
                )
                placedIds.insert(special.id)
            }

            // Tier 4: proportional spread — no date, no matching arc. Deterministic sequence
            // key (own parsed number, then id) so rescans never reshuffle already-placed
            // specials just because they were enumerated in a different order this time.
            guard let minPos = mainline.first?.position, let maxPos = mainline.last?.position,
                  maxPos > minPos, mainline.count >= 2 else {
                // Tier 5: no mainline siblings at all in this group — always-last safety net.
                let undated = specials.filter { !placedIds.contains($0.id) }
                    .sorted { sequenceKey($0) < sequenceKey($1) }
                for (idx, special) in undated.enumerated() {
                    results[special.id] = ReadingOrderResult(
                        position: alwaysLastBand + idx, confidence: 0,
                        reason: "No mainline issues found in this series to place it relative to"
                    )
                }
                continue
            }

            let undated = specials.filter { !placedIds.contains($0.id) }
                .sorted { sequenceKey($0) < sequenceKey($1) }
            let n = undated.count
            guard n > 0 else { continue }
            for (idx, special) in undated.enumerated() {
                let fraction = Double(idx + 1) / Double(n + 1)
                let pos = minPos + Int((Double(maxPos - minPos) * fraction).rounded())
                results[special.id] = ReadingOrderResult(
                    position: pos, confidence: 60,
                    reason: "No date or story-arc match — estimated position #\(idx + 1) of \(n) among this series' specials"
                )
            }
        }

        return results
    }

    /// Deterministic sort key for specials with no other placement signal: own parsed number
    /// (e.g. "Annual #3" -> 3) first, then comic id — never dependent on scan/array order, so
    /// a rescan never reshuffles specials that were already placed by a previous run.
    private static func sequenceKey(_ input: ReadingOrderInput) -> (Double, Int64) {
        (input.legacyNumber ?? .infinity, input.id)
    }

    private static func formatNumber(_ n: Double) -> String {
        n == n.rounded(.towardZero) ? String(Int(n)) : String(n)
    }
}
