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
}

/// Classifies a comic as a regular issue, annual, special, one-shot, etc. from its title,
/// issue number, and ComicInfo.xml Format -- used for special-issue sorting and library health checks.
enum ComicTypeClassifier {
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

    static func classify(issueNumber: String?, title: String, format: String? = nil) -> ComicType {
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
        if let num = Double(trimmed) {
            if num == 0 { return .issueZero }
            if num != num.rounded(.towardZero) { return .pointIssue }
        }
        return .regular
    }
}

/// Sort positions: regular issues by issue number, specials in a band after them.
enum ComicSortClassifier {
    static func isSpecialIssue(issueNumber: String?, title: String) -> Bool {
        ComicTypeClassifier.classify(issueNumber: issueNumber, title: title).needsPlacement
    }

    static let specialBandOffset = 1_000_000

    static let mainlinePositionStride = 100
}
