import Foundation

enum ComicSortClassifier {
    static func isSpecialIssue(issueNumber: String?, title: String, series: String) -> Bool {
        ReadingOrderEngine.classify(issueNumber: issueNumber, title: title, series: series).needsPlacement
    }

    static let specialBandOffset = 1_000_000

    static let mainlinePositionStride = 100

    static func seededPosition(issueNumber: String?, title: String, series: String, numericIssueOrId: Int) -> Int {
        let band = isSpecialIssue(issueNumber: issueNumber, title: title, series: series) ? specialBandOffset : 0
        return band + numericIssueOrId * mainlinePositionStride
    }
}

enum ComicFileNaming {
    static func idealFilename(series: String, issueNumber: String?, title: String, fileExtension: String) -> String {
        var base = series

        let type = ReadingOrderEngine.classify(issueNumber: issueNumber, title: title, series: series)
        if let suffix = type.fileNameSuffix, !series.uppercased().contains(suffix.uppercased()) {
            base += " " + suffix
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
