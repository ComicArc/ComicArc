import Foundation

enum ComicSortClassifier {
    static func isSpecialIssue(issueNumber: String?, title: String, series: String) -> Bool {
        ReadingOrderEngine.classify(issueNumber: issueNumber, title: title, series: series).needsPlacement
    }

    static let specialBandOffset = 1_000_000

    static let mainlinePositionStride = 100
}

/// ComicArc's filename cleanup: a plain, predictable text normalization of whatever a file is
/// ALREADY named -- replace underscores with spaces, collapse repeated whitespace, nothing more.
///
/// This deliberately does NOT reconstruct a name from series/issue/edition metadata (an earlier
/// version of this did). That approach could produce a filename that looked authoritative but
/// silently disagreed with the file's real contents whenever the underlying metadata was wrong,
/// and its exact output was hard to predict from looking at the original filename. A plain text
/// cleanup is always predictable: the same substitution, every time, with no hidden reasoning.
enum ComicFileNaming {
    /// `currentName` is the file's existing name, without its extension.
    static func cleanedFilename(currentName: String, fileExtension: String) -> String {
        var name = currentName.replacingOccurrences(of: "_", with: " ")
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// One canonical GCD series name per (publisher, series) group, chosen by majority vote among
    /// whichever comics in that group have a non-nil `gcdSeriesName`. A single comic's own GCD
    /// match can fail (an issue with unusual/incomplete metadata) even though the rest of its
    /// series matched fine -- naively falling back to that one comic's raw `series` field in that
    /// case can lock it into a folder-derived abbreviation (e.g. "ASM (1963)" instead of the real
    /// "The Amazing Spider-Man") forever, since the resulting "ideal" filename then coincidentally
    /// matches whatever inconsistent name the file already has and looks like it needs no rename.
    /// Groups with zero matches at all are omitted -- callers should fall back to each comic's own
    /// `gcdSeriesName ?? series` in that case.
    static func canonicalSeriesNames(for entries: [(publisher: String, series: String, gcdSeriesName: String?)]) -> [String: String] {
        var votes: [String: [String: Int]] = [:]
        for entry in entries {
            guard let gcdName = entry.gcdSeriesName, !gcdName.isEmpty else { continue }
            let key = "\(entry.publisher):\(entry.series)"
            votes[key, default: [:]][gcdName, default: 0] += 1
        }
        return votes.compactMapValues { candidates in candidates.max { $0.value < $1.value }?.key }
    }

    /// Layer 4 (Display Information): the single series name to show the user for a group of
    /// comics that conceptually share one identity -- a duplicate group, a series section, a
    /// search-result cluster -- so the same series never displays under two different names in
    /// two different parts of the app (e.g. the folder-derived "ASM (1963)" in one place and the
    /// GCD-verified "The Amazing Spider-Man" in another). Reuses `canonicalSeriesNames`'s
    /// majority-vote logic (already relied on for renaming) rather than re-deriving a separate
    /// notion of "what to call this." Falls back to the first comic's own `gcdSeriesName ?? series`
    /// when nothing in the group has a GCD match at all.
    static func displaySeriesName(for comics: [Comic]) -> String {
        guard let first = comics.first else { return "" }
        let key = "\(first.publisher):\(first.series)"
        let canonical = canonicalSeriesNames(for: comics.map {
            (publisher: $0.publisher, series: $0.series, gcdSeriesName: $0.gcdSeriesName)
        })
        return canonical[key] ?? first.gcdSeriesName ?? first.series
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
