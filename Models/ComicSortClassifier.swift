import Foundation

enum ComicSortClassifier {
    static let specialKeywords: [String] = [
        "ANNUAL", "SPECIAL", "HOLIDAY", "ONE-SHOT", "ONESHOT", "ONE SHOT",
        "PREVIEW", "GIANT-SIZE", "GIANT SIZE", "KING-SIZE", "KING SIZE",
        "DIRECTOR'S CUT", "DIRECTORS CUT",
    ]

    static func isSpecialIssue(issueNumber: String?, title: String, series: String) -> Bool {
        let haystack = [issueNumber ?? "", title, series].joined(separator: " ").uppercased()
        return specialKeywords.contains { haystack.contains($0) }
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
