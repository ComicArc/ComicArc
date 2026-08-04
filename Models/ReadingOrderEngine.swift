import Foundation

enum ComicType: String, Equatable {
    case regular
    case annual
    case oneShot
    case special
    case giantSize
    case kingSize
    case alpha
    case omega
    case issueZero
    case pointIssue
    case directorsCut
    case preview
    case fcbd
    case ashcan
    case holidaySpecial

    case tradePaperback
    case hardcover
    case omnibus
    case graphicNovel
    case compendium

    var needsPlacement: Bool {
        switch self {
        case .regular, .tradePaperback, .hardcover, .omnibus, .graphicNovel, .compendium:
            return false
        default:
            return true
        }
    }

    var fileNameSuffix: String? {
        switch self {
        case .annual:         return "Annual"
        case .oneShot:        return "One-Shot"
        case .special:        return "Special"
        case .giantSize:      return "Giant-Size"
        case .kingSize:       return "King-Size"
        case .holidaySpecial: return "Holiday Special"
        case .directorsCut:   return "Director's Cut"
        case .fcbd:           return "FCBD"
        case .ashcan:         return "Ashcan"
        case .preview:        return "Preview"
        default:              return nil
        }
    }
}

/// Publication Timeline: given a comic's identity and its series continuity, computes where it
/// sits on the objective, real-world publication chronology of its series -- separate from
/// `issue_number`/`volume`, which are display information. "Reading order" (what a user is shown,
/// including manual overrides and curated cross-series Reading Runs) is a *view* over this
/// timeline, not the timeline itself.
enum ReadingOrderEngine {
    /// Bounded to the comic's own issue-number/title text, deliberately excluding `series` -- a
    /// series (or story-arc) *name* that happens to contain a type keyword as an ordinary word
    /// (e.g. "Extra Special Adventures") must never misclassify every issue in it. A real annual/
    /// special/one-shot names itself as such in its own title or issue-number field, which is what
    /// actually gets searched. Matched at word boundaries, not as a bare substring, so a keyword
    /// embedded inside a longer word (e.g. "SPECIALIST") doesn't false-positive either.
    private static let typeKeywords: [(regex: NSRegularExpression, type: ComicType)] = compileKeywords([
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
    ])

    private static let formatKeywords: [(regex: NSRegularExpression, type: ComicType)] = compileKeywords([
        ("OMNIBUS", .omnibus), ("COMPENDIUM", .compendium),
        ("HARDCOVER", .hardcover), (" HC", .hardcover),
        ("GRAPHIC NOVEL", .graphicNovel), ("TPB", .tradePaperback), ("TRADE PAPERBACK", .tradePaperback),
    ])

    private static let comicInfoFormatMap: [(String, ComicType)] = [
        ("ANNUAL", .annual),
        ("ONE-SHOT", .oneShot), ("ONESHOT", .oneShot), ("ONE SHOT", .oneShot),
        ("SPECIAL", .special),
        ("GIANT-SIZE", .giantSize), ("GIANT SIZE", .giantSize), ("GIANT", .giantSize),
        ("KING-SIZE", .kingSize), ("KING SIZE", .kingSize),
        ("FCBD", .fcbd), ("FREE COMIC BOOK DAY", .fcbd),
        ("ASHCAN", .ashcan),
        ("PREVIEW", .preview),
        ("OMNIBUS", .omnibus), ("COMPENDIUM", .compendium),
        ("HARDCOVER", .hardcover),
        ("GRAPHIC NOVEL", .graphicNovel),
        ("TPB", .tradePaperback), ("TRADE PAPERBACK", .tradePaperback),
    ]

    private static func compileKeywords(_ pairs: [(String, ComicType)]) -> [(regex: NSRegularExpression, type: ComicType)] {
        pairs.compactMap { keyword, type in
            // Regex `\b` treats underscore as a word character, so it wouldn't find a boundary in
            // "_Annual_" -- exactly the separator comic filenames/titles actually use. Boundaries
            // here mean "not immediately flanked by a letter or digit" instead, so underscores,
            // hyphens, spaces, and punctuation all count as real separators.
            let escaped = NSRegularExpression.escapedPattern(for: keyword)
            let pattern = "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, type)
        }
    }

    private static func matches(_ regex: NSRegularExpression, in haystack: String) -> Bool {
        regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
    }

    static func classify(issueNumber: String?, title: String, series: String, format: String? = nil) -> ComicType {
        if let format, !format.isEmpty {
            let upper = format.uppercased()
            if let match = comicInfoFormatMap.first(where: { upper.contains($0.0) }) {
                return match.1
            }
        }

        let haystack = [issueNumber ?? "", title].joined(separator: " ").uppercased()

        for entry in typeKeywords where matches(entry.regex, in: haystack) { return entry.type }
        for entry in formatKeywords where matches(entry.regex, in: haystack) { return entry.type }

        let trimmed = (issueNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed == "ALPHA" { return .alpha }
        if trimmed == "OMEGA" { return .omega }
        if let num = parseLegacyNumber(issueNumber) {
            if num == 0 { return .issueZero }
            if num != num.rounded(.towardZero) { return .pointIssue }
        }
        return .regular
    }

    static func parseLegacyNumber(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }

    struct ReadingOrderInput {
        let id: Int64
        let groupKey: String
        let legacyNumber: Double?
        let comicType: ComicType
        let year: Int?
        let month: Int?
        let day: Int?
        let storyArc: String?
        let title: String
    }

    struct ReadingOrderResult {
        let position: Int
        let confidence: Int
        let reason: String
    }

    static let mainlineStride = 100_000
    static let alwaysLastBand = 10_000_000_000

    private static func mainlinePosition(for legacyNumber: Double) -> Int {
        let tenths = Int((legacyNumber * 10).rounded())
        return tenths * mainlineStride
    }

    private static func dateKey(year: Int, month: Int, day: Int?) -> Int {
        year * 10000 + month * 100 + (day ?? 15)
    }

    static func computeSeriesPositions(_ inputs: [ReadingOrderInput]) -> [Int64: ReadingOrderResult] {
        var results: [Int64: ReadingOrderResult] = [:]
        for (groupKey, group) in Dictionary(grouping: inputs, by: \.groupKey) {
            let mainline = placeMainline(group, into: &results)
            let mainlineDated = datedNeighbors(from: mainline)
            let specials = group.filter { $0.comicType.needsPlacement }

            var placedIds = Set<Int64>()
            placeByDateAnchor(specials, mainlineDated: mainlineDated, results: &results, placedIds: &placedIds)
            placeByStoryArc(specials, mainline: mainline, results: &results, placedIds: &placedIds)
            placeRemaining(specials, mainline: mainline, groupKey: groupKey, results: &results, placedIds: placedIds)
        }
        return results
    }

    // MARK: - Tier: mainline numbering (confidence 100)

    /// Every non-special issue with a parseable legacy number gets a position purely from that
    /// number -- the backbone the rest of this group's specials/annuals get placed relative to.
    private static func placeMainline(
        _ group: [ReadingOrderInput], into results: inout [Int64: ReadingOrderResult]
    ) -> [(input: ReadingOrderInput, position: Int)] {
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
        return mainline
    }

    private static func datedNeighbors(
        from mainline: [(input: ReadingOrderInput, position: Int)]
    ) -> [(input: ReadingOrderInput, position: Int)] {
        mainline.filter { $0.input.year != nil && $0.input.month != nil }
            .sorted { dateKey(year: $0.input.year!, month: $0.input.month!, day: $0.input.day) <
                      dateKey(year: $1.input.year!, month: $1.input.month!, day: $1.input.day) }
    }

    // MARK: - Tiers: date-anchored placement (confidence 100 between two neighbors, 85 with only one)

    /// A dated special either falls strictly between two dated mainline neighbors (full
    /// interpolation, confidence 100) or, when the series only has a single dated mainline issue
    /// to anchor against, gets placed just before/after it (confidence 85).
    private static func placeByDateAnchor(
        _ specials: [ReadingOrderInput],
        mainlineDated: [(input: ReadingOrderInput, position: Int)],
        results: inout [Int64: ReadingOrderResult],
        placedIds: inout Set<Int64>
    ) {
        var betweenNeighbors: [Int: [(special: ReadingOrderInput, specialKey: Int)]] = [:]
        var beforeOnlyAnchor: [(special: ReadingOrderInput, specialKey: Int)] = []
        var afterOnlyAnchor: [(special: ReadingOrderInput, specialKey: Int)] = []

        for special in specials {
            guard let sy = special.year, let sm = special.month else { continue }
            let specialKey = dateKey(year: sy, month: sm, day: special.day)

            let afterIdx = mainlineDated.firstIndex {
                dateKey(year: $0.input.year!, month: $0.input.month!, day: $0.input.day) > specialKey
            }

            if let afterIdx, afterIdx > 0 {
                betweenNeighbors[afterIdx - 1, default: []].append((special, specialKey))
            } else if mainlineDated.count == 1 {
                let onlyKey = dateKey(year: mainlineDated[0].input.year!, month: mainlineDated[0].input.month!, day: mainlineDated[0].input.day)
                if specialKey < onlyKey { beforeOnlyAnchor.append((special, specialKey)) }
                else { afterOnlyAnchor.append((special, specialKey)) }
            }
        }

        for (beforeIdx, bracket) in betweenNeighbors {
            let before = mainlineDated[beforeIdx]
            let after  = mainlineDated[beforeIdx + 1]
            guard after.position - before.position > 1 else { continue }
            let sorted = bracket.sorted {
                $0.specialKey != $1.specialKey ? $0.specialKey < $1.specialKey : sequenceKey($0.special) < sequenceKey($1.special)
            }
            let n = sorted.count
            for (idx, item) in sorted.enumerated() {
                let pos = n == 1
                    ? before.position + (after.position - before.position) / 2
                    : before.position + Int((Double(after.position - before.position) * (Double(idx + 1) / Double(n + 1))).rounded())
                results[item.special.id] = ReadingOrderResult(
                    position: pos, confidence: 100,
                    reason: "Cover date places it between \(before.input.title.isEmpty ? "the previous" : before.input.title) and \(after.input.title.isEmpty ? "the next" : after.input.title) issue"
                )
                placedIds.insert(item.special.id)
            }
        }

        guard let only = mainlineDated.first, mainlineDated.count == 1 else { return }
        for (side, reversed, offset) in [(beforeOnlyAnchor, true, -1), (afterOnlyAnchor, false, 1)] {
            let sorted = side.sorted {
                $0.specialKey != $1.specialKey
                    ? (reversed ? $0.specialKey > $1.specialKey : $0.specialKey < $1.specialKey)
                    : sequenceKey($0.special) < sequenceKey($1.special)
            }
            for (idx, item) in sorted.enumerated() {
                let pos = only.position + offset * (idx + 1)
                results[item.special.id] = ReadingOrderResult(
                    position: pos, confidence: 85,
                    reason: "Cover date places it \(offset < 0 ? "before" : "after") \(only.input.title.isEmpty ? "the only dated issue in this series" : only.input.title) (only one dated neighbor available)"
                )
                placedIds.insert(item.special.id)
            }
        }
    }

    // MARK: - Tier: story-arc adjacency (confidence 85, or 90 if the year also corroborates)

    private static func placeByStoryArc(
        _ specials: [ReadingOrderInput],
        mainline: [(input: ReadingOrderInput, position: Int)],
        results: inout [Int64: ReadingOrderResult],
        placedIds: inout Set<Int64>
    ) {
        var byMatch: [Int64: (matchPos: Int, matchTitle: String, matchYear: Int?, items: [(special: ReadingOrderInput, arc: String)])] = [:]
        for special in specials where !placedIds.contains(special.id) {
            guard let arc = special.storyArc, !arc.isEmpty else { continue }
            guard let match = mainline.first(where: { $0.input.storyArc == arc }) else { continue }
            byMatch[match.input.id, default: (match.position, match.input.title, match.input.year, [])].items.append((special, arc))
        }
        for (_, bucket) in byMatch {
            let sorted = bucket.items.sorted { sequenceKey($0.special) < sequenceKey($1.special) }
            for (idx, item) in sorted.enumerated() {
                let corroborated = item.special.year != nil && item.special.year == bucket.matchYear
                results[item.special.id] = ReadingOrderResult(
                    position: bucket.matchPos + idx + 1, confidence: corroborated ? 90 : 85,
                    reason: "Shares story arc \"\(item.arc)\" with \(bucket.matchTitle.isEmpty ? "a mainline issue" : bucket.matchTitle)"
                )
                placedIds.insert(item.special.id)
            }
        }
    }

    // MARK: - Tier: proportional spread (confidence 60), or always-last when there's nothing to anchor to (confidence 0)

    private static func placeRemaining(
        _ specials: [ReadingOrderInput],
        mainline: [(input: ReadingOrderInput, position: Int)],
        groupKey: String,
        results: inout [Int64: ReadingOrderResult],
        placedIds: Set<Int64>
    ) {
        let undated = specials.filter { !placedIds.contains($0.id) }
            .sorted { sequenceKey($0) < sequenceKey($1) }

        guard let minPos = mainline.first?.position, let maxPos = mainline.last?.position,
              maxPos > minPos, mainline.count >= 2 else {
            let band = alwaysLastBand + stableHash(groupKey) * mainlineStride
            for (idx, special) in undated.enumerated() {
                results[special.id] = ReadingOrderResult(
                    position: band + idx, confidence: 0,
                    reason: "No mainline issues found in this series to place it relative to"
                )
            }
            return
        }

        let n = undated.count
        guard n > 0 else { return }
        for (idx, special) in undated.enumerated() {
            let fraction = Double(idx + 1) / Double(n + 1)
            let pos = minPos + Int((Double(maxPos - minPos) * fraction).rounded())
            results[special.id] = ReadingOrderResult(
                position: pos, confidence: 60,
                reason: "No date or story-arc match — estimated position #\(idx + 1) of \(n) among this series' specials"
            )
        }
    }

    private static func sequenceKey(_ input: ReadingOrderInput) -> (Double, Int64) {
        (input.legacyNumber ?? .infinity, input.id)
    }

    private static func formatNumber(_ n: Double) -> String {
        n == n.rounded(.towardZero) ? String(Int(n)) : String(n)
    }

    private static func stableHash(_ s: String) -> Int {
        var hash: UInt64 = 14695981039346656037
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Int(hash % 1_000_000)
    }
}
