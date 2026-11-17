import Foundation

/// What kind of book a file is, judged from its own title/issue text (never the series name, so a
/// series called "Extra Special Adventures" isn't misread) and its ComicInfo.xml Format.
enum ComicType: String, Sendable {
    case regular, annual, oneShot, special, giantSize, kingSize, alpha, omega, issueZero, pointIssue
    case directorsCut, preview, fcbd, ashcan, holidaySpecial
    case tradePaperback, hardcover, omnibus, graphicNovel, compendium

    /// Specials sort after the regular run of their series.
    var sortsAfterRegularIssues: Bool {
        switch self {
        case .regular, .tradePaperback, .hardcover, .omnibus, .graphicNovel, .compendium: return false
        default: return true
        }
    }
}

enum ComicClassifier {
    /// Sort position = special band + issue number × stride, so specials follow the regular run and
    /// manual reordering has room to insert between issues.
    static let specialBandOffset = 1_000_000
    static let positionStride = 100

    static func classify(issueNumber: String?, title: String, format: String? = nil) -> ComicType {
        if let format, !format.isEmpty {
            let upper = format.uppercased()
            if let match = formatMap.first(where: { upper.contains($0.0) }) { return match.1 }
        }
        let haystack = "\(issueNumber ?? "") \(title)".uppercased()
        for (regex, type) in typeKeywords where matches(regex, haystack) { return type }
        for (regex, type) in collectedKeywords where matches(regex, haystack) { return type }

        let trimmed = (issueNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed == "ALPHA" { return .alpha }
        if trimmed == "OMEGA" { return .omega }
        if let n = Double(trimmed) {
            if n == 0 { return .issueZero }
            if n != n.rounded(.towardZero) { return .pointIssue }
        }
        return .regular
    }

    static func isSpecial(issueNumber: String?, title: String) -> Bool {
        classify(issueNumber: issueNumber, title: title).sortsAfterRegularIssues
    }

    // MARK: - Keyword tables

    private static let typeKeywords = compile([
        ("FCBD", .fcbd), ("FREE COMIC BOOK DAY", .fcbd), ("ASHCAN", .ashcan), ("ANNUAL", .annual),
        ("ONE-SHOT", .oneShot), ("ONESHOT", .oneShot), ("ONE SHOT", .oneShot), ("HOLIDAY", .holidaySpecial),
        ("DIRECTOR'S CUT", .directorsCut), ("DIRECTORS CUT", .directorsCut), ("PREVIEW", .preview),
        ("GIANT-SIZE", .giantSize), ("GIANT SIZE", .giantSize), ("KING-SIZE", .kingSize),
        ("KING SIZE", .kingSize), ("SPECIAL", .special),
    ])

    private static let collectedKeywords = compile([
        ("OMNIBUS", .omnibus), ("COMPENDIUM", .compendium), ("HARDCOVER", .hardcover), (" HC", .hardcover),
        ("GRAPHIC NOVEL", .graphicNovel), ("TPB", .tradePaperback), ("TRADE PAPERBACK", .tradePaperback),
    ])

    private static let formatMap: [(String, ComicType)] = [
        ("ANNUAL", .annual), ("ONE-SHOT", .oneShot), ("ONESHOT", .oneShot), ("ONE SHOT", .oneShot),
        ("SPECIAL", .special), ("GIANT-SIZE", .giantSize), ("GIANT SIZE", .giantSize), ("GIANT", .giantSize),
        ("KING-SIZE", .kingSize), ("KING SIZE", .kingSize), ("FCBD", .fcbd), ("FREE COMIC BOOK DAY", .fcbd),
        ("ASHCAN", .ashcan), ("PREVIEW", .preview), ("OMNIBUS", .omnibus), ("COMPENDIUM", .compendium),
        ("HARDCOVER", .hardcover), ("GRAPHIC NOVEL", .graphicNovel), ("TPB", .tradePaperback),
        ("TRADE PAPERBACK", .tradePaperback),
    ]

    /// Word boundaries mean "not next to a letter or digit": regex `\b` treats `_` as a word
    /// character, and filenames use underscores as separators.
    private static func compile(_ pairs: [(String, ComicType)]) -> [(NSRegularExpression, ComicType)] {
        pairs.compactMap { keyword, type in
            let pattern = "(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: keyword))(?![A-Za-z0-9])"
            return (try? NSRegularExpression(pattern: pattern)).map { ($0, type) }
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
