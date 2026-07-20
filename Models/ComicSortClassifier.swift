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

    /// Position band used to seed the `comics.position` column so the default reading
    /// order is correct without requiring every query to re-run the classifier: mainline
    /// issues sort by their numeric issue (or insertion id as a fallback), and specials
    /// are pushed into a distinct upper band, ordered the same way within it.
    static let specialBandOffset = 1_000_000

    /// Mainline positions are spaced 100 apart (rather than 1) specifically to leave room
    /// for positionSpecialsChronologically(DatabaseManager.swift) to interpolate a dated
    /// special issue's position between two consecutive mainline issues without collision —
    /// e.g. issue #12 at 1200 and #13 at 1300 leaves room for an annual at 1250. A dense
    /// (gap-of-1) scheme would make every chronological insertion "no room" by construction.
    static let mainlinePositionStride = 100

    static func seededPosition(issueNumber: String?, title: String, series: String, numericIssueOrId: Int) -> Int {
        let band = isSpecialIssue(issueNumber: issueNumber, title: title, series: series) ? specialBandOffset : 0
        return band + numericIssueOrId * mainlinePositionStride
    }
}

// MARK: - File naming

// Computes the filename ComicArc's own scanner parses most reliably: folder structure gives
// publisher/character/series (see LibraryScanner.folderComponents), so the filename itself
// only needs to carry the series name, issue number, and — for specials — whichever keyword
// made it classify as one, so a rename never accidentally undoes that classification. Used by
// the in-app "Rename Files to Match Library" tool (Views/Settings/RenameFilesView.swift) and
// documented in FILE_NAMING.md for anyone who'd rather rename by hand.
enum ComicFileNaming {
    static func idealFilename(series: String, issueNumber: String?, title: String, fileExtension: String) -> String {
        var base = series
        // Preserve whichever special keyword the comic was actually classified under (Annual,
        // Special, One-Shot, ...) — dropping it would silently reclassify the comic as a
        // mainline issue the next time its metadata gets re-derived from the filename.
        let haystack = ([issueNumber ?? "", title, series]).joined(separator: " ").uppercased()
        if let keyword = ComicSortClassifier.specialKeywords.first(where: { haystack.contains($0) }),
           !series.uppercased().contains(keyword) {
            base += " " + keyword.capitalized
        }
        let issue = (issueNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = issue.isEmpty ? base : "\(base) #\(issue)"
        let safe = name
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(safe).\(fileExtension)"
    }
}
