import Foundation

struct LibraryHealthReport {
    struct SeriesIssue: Identifiable {
        let publisher: String; let series: String; let count: Int
        var id: String { "\(publisher):\(series)" }
    }

    var duplicateGroupCount: Int = 0
    var multipleFirstIssues: [SeriesIssue] = []
    var numberingGaps: [SeriesIssue] = []
    var multipleVolumes: [SeriesIssue] = []
    var corruptArchiveCount: Int = 0
    var numberingMismatches: [SeriesIssue] = []

    var isEmpty: Bool {
        duplicateGroupCount == 0 && multipleFirstIssues.isEmpty
            && numberingGaps.isEmpty && multipleVolumes.isEmpty
            && corruptArchiveCount == 0 && numberingMismatches.isEmpty
    }

    var totalCount: Int {
        duplicateGroupCount + multipleFirstIssues.count
            + numberingGaps.count + multipleVolumes.count
            + corruptArchiveCount + numberingMismatches.count
    }
}

enum LibraryHealthAnalyzer {
    static func analyze(db: DatabaseManager = .shared) -> LibraryHealthReport {
        LibraryHealthReport(
            duplicateGroupCount: db.duplicateGroups().count,
            multipleFirstIssues: db.seriesWithMultipleFirstIssues().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            numberingGaps: db.seriesWithNumberingGaps().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            multipleVolumes: db.seriesWithMultipleVolumes().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            corruptArchiveCount: db.corruptArchiveCount(),
            numberingMismatches: db.seriesWithNumberingMismatches().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            }
        )
    }
}
