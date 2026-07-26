import Foundation

/// Resolves a comic's canonical series/publisher/issue-number from every raw fact captured about
/// it, all in one named, testable place -- so "which source wins" is never inlined at the point of
/// capture (as it previously was in `LibraryScanner.parseMeta`) and can be re-run later using
/// exactly the same rule a fresh import used (see `DatabaseManager`'s conflict-detection path and
/// the existing-library audit migration).
///
/// ComicInfo.xml wins when present and non-empty; folder structure (or, for issue number, the
/// filename) is the fallback when it isn't. This deliberately does NOT decide whether to apply a
/// differing result to an already-imported comic -- that is the caller's job, since only the
/// caller knows whether there's an existing value worth protecting.
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
