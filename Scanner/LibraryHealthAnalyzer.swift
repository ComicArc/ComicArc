import Foundation

struct LibraryHealthReport {
    struct SeriesIssue: Identifiable {
        let publisher: String; let series: String; let count: Int
        var id: String { "\(publisher):\(series)" }
    }

    var duplicateGroupCount: Int = 0
    var multipleFirstIssues: [SeriesIssue] = []
    var needsSpecialReposition: [SeriesIssue] = []
    var numberingGaps: [SeriesIssue] = []
    var multipleVolumes: [SeriesIssue] = []
    var missingComicInfoCount: Int = 0
    var corruptArchiveCount: Int = 0
    var brokenSeriesLinkCycles: [[String]] = []
    var numberingMismatches: [SeriesIssue] = []

    var isEmpty: Bool {
        duplicateGroupCount == 0 && multipleFirstIssues.isEmpty && needsSpecialReposition.isEmpty
            && numberingGaps.isEmpty && multipleVolumes.isEmpty && missingComicInfoCount == 0
            && corruptArchiveCount == 0 && brokenSeriesLinkCycles.isEmpty && numberingMismatches.isEmpty
    }

    var totalCount: Int {
        duplicateGroupCount + multipleFirstIssues.count + needsSpecialReposition.count
            + numberingGaps.count + multipleVolumes.count + missingComicInfoCount
            + corruptArchiveCount + brokenSeriesLinkCycles.count + numberingMismatches.count
    }
}

enum LibraryHealthAnalyzer {
    static func analyze(db: DatabaseManager = .shared) -> LibraryHealthReport {
        LibraryHealthReport(
            duplicateGroupCount: db.duplicateGroups().count,
            multipleFirstIssues: db.seriesWithMultipleFirstIssues().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            needsSpecialReposition: db.seriesNeedingSpecialReposition().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            numberingGaps: db.seriesWithNumberingGaps().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            multipleVolumes: db.seriesWithMultipleVolumes().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            },
            missingComicInfoCount: db.missingComicInfoCount(),
            corruptArchiveCount: db.corruptArchiveCount(),
            brokenSeriesLinkCycles: db.seriesLinkCycles(),
            numberingMismatches: db.seriesWithNumberingMismatches().map {
                .init(publisher: $0.publisher, series: $0.series, count: $0.count)
            }
        )
    }
}
