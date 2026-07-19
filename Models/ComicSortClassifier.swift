import Foundation

// MARK: - Mainline vs. special-issue classification
//
// Single source of truth for "is this a regular numbered issue, or an annual/special/
// one-shot/etc. that should be pushed to the end of the reading order." Used both from
// Swift (ComicSortClassifier.isSpecialIssue) and from raw SQL (the `is_special_issue`
// scalar function DatabaseManager registers, backed by the same logic below) so every
// query — library, series, search, duplicates — agrees on the same answer.
//
// Deliberately keyword-based rather than tied to any specific publisher or numbering
// scheme: ComicInfo.xml doesn't reliably carry a machine-readable "this is an annual"
// flag, but publishers overwhelmingly spell it out in the title, series name, or the
// issue number field itself ("Annual", "Holiday Special", "1999 Annual", etc.).
enum ComicSortClassifier {
    static let specialKeywords: [String] = [
        "ANNUAL", "SPECIAL", "HOLIDAY", "ONE-SHOT", "ONESHOT", "ONE SHOT",
        "PREVIEW", "GIANT-SIZE", "GIANT SIZE", "KING-SIZE", "KING SIZE",
        "DIRECTOR'S CUT", "DIRECTORS CUT",
    ]

    /// True if this issue should be sorted after every regular numbered issue in its series.
    static func isSpecialIssue(issueNumber: String?, title: String, series: String) -> Bool {
        let haystack = [issueNumber ?? "", title, series].joined(separator: " ").uppercased()
        return specialKeywords.contains { haystack.contains($0) }
    }

    /// 0 = mainline (sorts first), 1 = special (sorts last).
    static func priority(issueNumber: String?, title: String, series: String) -> Int {
        isSpecialIssue(issueNumber: issueNumber, title: title, series: series) ? 1 : 0
    }

    /// Position band used to seed the `comics.position` column so the default reading
    /// order is correct without requiring every query to re-run the classifier: mainline
    /// issues sort by their numeric issue (or insertion id as a fallback), and specials
    /// are pushed into a distinct upper band, ordered the same way within it.
    static let specialBandOffset = 1_000_000

    static func seededPosition(issueNumber: String?, title: String, series: String, numericIssueOrId: Int) -> Int {
        let band = isSpecialIssue(issueNumber: issueNumber, title: title, series: series) ? specialBandOffset : 0
        return band + numericIssueOrId
    }
}
