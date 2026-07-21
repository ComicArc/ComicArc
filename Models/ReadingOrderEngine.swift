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

    /// Suffix appended to an ideal filename (see `ComicFileNaming`) to distinguish this
    /// type from a regular issue. `nil` means no suffix is needed.
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

enum ReadingOrderEngine {

    private static let formatKeywords: [(String, ComicType)] = [
        ("OMNIBUS", .omnibus), ("COMPENDIUM", .compendium),
        ("HARDCOVER", .hardcover), (" HC", .hardcover),
        ("GRAPHIC NOVEL", .graphicNovel), ("TPB", .tradePaperback), ("TRADE PAPERBACK", .tradePaperback),
    ]

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

    static func classify(issueNumber: String?, title: String, series: String) -> ComicType {
        let haystack = [issueNumber ?? "", title, series].joined(separator: " ").uppercased()

        for (keyword, type) in typeKeywords where haystack.contains(keyword) {
            return type
        }
        for (keyword, type) in formatKeywords where haystack.contains(keyword) {
            return type
        }

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

        for (_, group) in Dictionary(grouping: inputs, by: \.groupKey) {

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

            for special in specials {
                guard let sy = special.year, let sm = special.month else { continue }
                let specialKey = dateKey(year: sy, month: sm, day: special.day)

                let afterIdx = mainlineDated.firstIndex {
                    dateKey(year: $0.input.year!, month: $0.input.month!, day: $0.input.day) > specialKey
                }

                if let afterIdx, afterIdx > 0 {

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

            for special in specials where !placedIds.contains(special.id) {
                guard let arc = special.storyArc, !arc.isEmpty else { continue }
                guard let match = mainline.first(where: { $0.input.storyArc == arc }) else { continue }
                results[special.id] = ReadingOrderResult(
                    position: match.position + 1, confidence: 85,
                    reason: "Shares story arc \"\(arc)\" with \(match.input.title.isEmpty ? "a mainline issue" : match.input.title)"
                )
                placedIds.insert(special.id)
            }

            guard let minPos = mainline.first?.position, let maxPos = mainline.last?.position,
                  maxPos > minPos, mainline.count >= 2 else {

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

    private static func sequenceKey(_ input: ReadingOrderInput) -> (Double, Int64) {
        (input.legacyNumber ?? .infinity, input.id)
    }

    private static func formatNumber(_ n: Double) -> String {
        n == n.rounded(.towardZero) ? String(Int(n)) : String(n)
    }
}
