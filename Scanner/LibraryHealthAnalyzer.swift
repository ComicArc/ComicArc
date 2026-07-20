import Foundation

/// Post-scan diagnostics ("Import Wizard"): a read-only triage over data already in the DB.
/// Of the problem types this surfaces, only `needsSpecialReposition` is genuinely one-click
/// auto-fixable (it just calls the existing `positionSpecialsChronologically()`); the rest are
/// detected here and deep-link into an existing manual-fix screen, or are report-only because
/// no valid repair action exists under the "never rename files, never rewrite ComicInfo.xml"
/// constraint — see the Reading Order Engine Phase 2 plan for the per-item reasoning.
struct LibraryHealthReport {
    struct SeriesIssue: Identifiable {
        let publisher: String; let series: String; let count: Int
        var id: String { "\(publisher):\(series)" }
    }

    var duplicateGroupCount: Int = 0
    var multipleFirstIssues: [SeriesIssue] = []
    var unparseableNumbering: [Comic] = []
    var missingComicInfo: [SeriesIssue] = []
    var needsSpecialReposition: [SeriesIssue] = []

    var isEmpty: Bool {
        duplicateGroupCount == 0 && multipleFirstIssues.isEmpty && unparseableNumbering.isEmpty &&
        missingComicInfo.isEmpty && needsSpecialReposition.isEmpty
    }

    var totalCount: Int {
        duplicateGroupCount + multipleFirstIssues.count + unparseableNumbering.count +
        missingComicInfo.count + needsSpecialReposition.count
    }
}

enum LibraryHealthAnalyzer {
    static func analyze(db: DatabaseManager = .shared) -> LibraryHealthReport {
        LibraryHealthReport(
            duplicateGroupCount: db.duplicateGroups().count,
            multipleFirstIssues: db.seriesWithMultipleFirstIssues().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            unparseableNumbering: db.unparseableIssueNumberComics(),
            missingComicInfo: db.seriesMissingComicInfo().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            needsSpecialReposition: db.seriesNeedingSpecialReposition().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            }
        )
    }
}
