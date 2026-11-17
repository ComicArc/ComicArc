import Foundation

/// Decides a comic's series, publisher and issue number from everything known about it
/// (ComicInfo.xml, folders, filename), so imports and later re-checks use the same rule.
enum ComicIdentityResolver {
    struct RawFacts {
        let comicInfoSeries: String?
        let comicInfoPublisher: String?
        let comicInfoIssueNumber: String?
        let folderSeries: String?
        let folderPublisher: String?
        let filenameIssueNumber: String?
    }

    struct Resolved {
        let series: String
        let publisher: String
        let issueNumber: String?
        let seriesSource: String
        let publisherSource: String
        let issueNumberSource: String
    }

    static let comicInfoSource = "ComicInfo.xml"
    static let folderSource = "folder"
    static let filenameSource = "filename"
    static let defaultSource = "default"

    static func resolve(_ facts: RawFacts) -> Resolved {
        let (series, seriesSource) = pick(facts.comicInfoSeries, comicInfoSource, facts.folderSeries, folderSource, default: "General")
        let (publisher, publisherSource) = pick(facts.comicInfoPublisher, comicInfoSource, facts.folderPublisher, folderSource, default: "Unknown")

        let issueNumber: String?
        let issueNumberSource: String
        if let n = nonEmpty(facts.comicInfoIssueNumber) {
            issueNumber = n; issueNumberSource = comicInfoSource
        } else if let n = nonEmpty(facts.filenameIssueNumber) {
            issueNumber = n; issueNumberSource = filenameSource
        } else {
            issueNumber = nil; issueNumberSource = defaultSource
        }

        return Resolved(series: series, publisher: publisher, issueNumber: issueNumber,
                         seriesSource: seriesSource, publisherSource: publisherSource, issueNumberSource: issueNumberSource)
    }

    private static func pick(_ primary: String?, _ primarySource: String, _ fallback: String?, _ fallbackSource: String,
                              default defaultValue: String) -> (String, String) {
        if let v = nonEmpty(primary) { return (v, primarySource) }
        if let v = nonEmpty(fallback) { return (v, fallbackSource) }
        return (defaultValue, defaultSource)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

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

/// Classifies a comic (regular issue, annual, special, one-shot...) from its title, issue number
/// and ComicInfo.xml Format.
enum ComicTypeClassifier {
    /// Only the comic's own title/issue text is checked, never the series name, so a series like
    /// "Extra Special Adventures" isn't misclassified.
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
            // Boundaries mean "not flanked by a letter or digit", because regex `\b` treats `_` as
            // a word character.
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

enum ComicSortClassifier {
    static func isSpecialIssue(issueNumber: String?, title: String) -> Bool {
        ComicTypeClassifier.classify(issueNumber: issueNumber, title: title).needsPlacement
    }

    static let specialBandOffset = 1_000_000

    static let mainlinePositionStride = 100
}

/// Filename cleanup: replaces underscores with spaces and collapses whitespace. It never rebuilds a
/// name from metadata, so it can't produce a name that disagrees with the file.
enum ComicFileNaming {
    /// A parenthesized year (or range) followed by a redundant second year, e.g. "Batman
    /// (2016-2020) (2016)". The first is kept.
    private static let duplicateYearParenthetical = try! NSRegularExpression(
        pattern: #"\((\d{4})(?:-\d{0,4})?\)\s+\(\d{4}\)"#
    )

    private static func collapsingDuplicateYearParenthetical(_ name: String) -> String {
        let range = NSRange(name.startIndex..., in: name)
        return duplicateYearParenthetical.stringByReplacingMatches(in: name, range: range, withTemplate: "($1)")
    }

    static func cleanedFilename(currentName: String, fileExtension: String) -> String {
        var name = currentName.replacingOccurrences(of: "_", with: " ")
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = collapsingDuplicateYearParenthetical(name)
        return "\(name).\(fileExtension)"
    }

    /// One cleaned-up name per comic id. Collisions are checked by `RenameFilesView` before
    /// anything is renamed.
    static func idealFilenames(for comics: [Comic]) -> [Int64: String] {
        Dictionary(uniqueKeysWithValues: comics.map { comic in
            let currentName = URL(fileURLWithPath: comic.filePath).deletingPathExtension().lastPathComponent
            return (comic.id, cleanedFilename(currentName: currentName, fileExtension: comic.fileExtension))
        })
    }

    /// Count-only version, for the post-scan suggestion banner.
    static func renameCandidateCount(for comics: [Comic]) -> Int {
        let idealNames = idealFilenames(for: comics)
        return comics.reduce(into: 0) { count, comic in
            guard let idealName = idealNames[comic.id] else { return }
            if URL(fileURLWithPath: comic.filePath).lastPathComponent != idealName { count += 1 }
        }
    }
}
