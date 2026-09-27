import Foundation

/// ComicArc's filename cleanup: a plain, predictable text normalization of whatever a file is
/// ALREADY named -- replace underscores with spaces, collapse repeated whitespace, nothing more.
///
/// This deliberately does NOT reconstruct a name from series/issue/edition metadata (an earlier
/// version of this did). That approach could produce a filename that looked authoritative but
/// silently disagreed with the file's real contents whenever the underlying metadata was wrong,
/// and its exact output was hard to predict from looking at the original filename. A plain text
/// cleanup is always predictable: the same substitution, every time, with no hidden reasoning.
enum ComicFileNaming {
    /// Matches a year (optionally a range like "2016-2020" or open-ended "2016-") in parentheses,
    /// immediately followed by a second, redundant bare-year parenthetical -- e.g. some scanners/
    /// downloaders leave both "Batman (2016-2020) (2016)" and "Batman (2016) (2016)" behind.
    /// Always keeps the first parenthetical's year and drops the second one entirely.
    private static let duplicateYearParenthetical = try! NSRegularExpression(
        pattern: #"\((\d{4})(?:-\d{0,4})?\)\s+\(\d{4}\)"#
    )

    private static func collapsingDuplicateYearParenthetical(_ name: String) -> String {
        let range = NSRange(name.startIndex..., in: name)
        return duplicateYearParenthetical.stringByReplacingMatches(in: name, range: range, withTemplate: "($1)")
    }

    /// `currentName` is the file's existing name, without its extension.
    static func cleanedFilename(currentName: String, fileExtension: String) -> String {
        var name = currentName.replacingOccurrences(of: "_", with: " ")
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = collapsingDuplicateYearParenthetical(name)
        return "\(name).\(fileExtension)"
    }

    /// One cleaned-up name per comic, keyed by id. Collisions (two files that would end up with
    /// the identical final name) are still caught -- just not here: `RenameFilesView` already
    /// checks the full destination path against the whole batch and skips/flags any real conflict
    /// before anything is applied, which stays correct no matter how the name itself is computed.
    static func idealFilenames(for comics: [Comic]) -> [Int64: String] {
        Dictionary(uniqueKeysWithValues: comics.map { comic in
            let currentName = URL(fileURLWithPath: comic.filePath).deletingPathExtension().lastPathComponent
            return (comic.id, cleanedFilename(currentName: currentName, fileExtension: comic.fileExtension))
        })
    }

    /// Cheap count-only variant of the same walk `RenameFilesView.load()` does for its full
    /// candidate list -- lets a post-scan banner ask "does anything need renaming?" without
    /// building the whole per-file list just to throw it away.
    static func renameCandidateCount(for comics: [Comic]) -> Int {
        let idealNames = idealFilenames(for: comics)
        return comics.reduce(into: 0) { count, comic in
            guard let idealName = idealNames[comic.id] else { return }
            if URL(fileURLWithPath: comic.filePath).lastPathComponent != idealName { count += 1 }
        }
    }
}
