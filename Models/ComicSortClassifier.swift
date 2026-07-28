import Foundation

enum ComicSortClassifier {
    static func isSpecialIssue(issueNumber: String?, title: String, series: String) -> Bool {
        ReadingOrderEngine.classify(issueNumber: issueNumber, title: title, series: series).needsPlacement
    }

    static let specialBandOffset = 1_000_000

    static let mainlinePositionStride = 100
}

/// ComicArc's canonical filename standard, applied everywhere a filename is generated (bulk
/// Rename Files, the single-comic "fix this filename" action, and anywhere that needs to know
/// what a comic's filename *should* be) -- there is exactly one function that decides this
/// format, `idealFilename`, so the shape can never drift between callers.
///
/// The template is `Series [Type Suffix] (Edition) #Issue [(Disambiguator)].ext`, where `Edition`
/// is the comic's own Volume tag if it has one, else its cover year if known, else omitted --
/// e.g. `Amazing Spider-Man (1963) #001.cbz`, `Amazing Spider-Man (1999) #001.cbz` (a Vol. 2
/// relaunch of the same series name), `Robin (2009).cbz` (a TPB with no issue number), or
/// `Watchmen #001.cbz` (no edition signal available at all). This is deterministic and always
/// applied -- unlike a collision-driven scheme, the same comic always produces the same filename
/// shape regardless of what else happens to be in the library at rename time.
enum ComicFileNaming {
    static func idealFilename(series: String, issueNumber: String?, title: String, fileExtension: String,
                              edition: String? = nil, disambiguator: String? = nil) -> String {
        var base = series

        let type = ReadingOrderEngine.classify(issueNumber: issueNumber, title: title, series: series)
        if let suffix = type.fileNameSuffix, !series.uppercased().contains(suffix.uppercased()) {
            base += " " + suffix
        }
        // Skip the edition marker if the series name already ends with that exact parenthetical --
        // a very common real-world folder-naming convention (e.g. a folder literally named
        // "Robin (1993)") would otherwise double up into "Robin (1993) (1993) #001.cbz".
        if let edition, !edition.isEmpty, !base.hasSuffix("(\(edition))") {
            base += " (\(edition))"
        }
        let issue = (issueNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var name = issue.isEmpty ? base : "\(base) #\(paddedIssueNumber(issue))"
        if let disambiguator, !disambiguator.isEmpty {
            name += " (\(disambiguator))"
        }
        let safe = name
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(safe).\(fileExtension)"
    }

    /// The comic's own edition marker for the canonical format -- its Volume tag if present, else
    /// its cover year if known, else `nil` (graceful degradation for the many real comics with
    /// neither signal). Always computed and shown, not just when disambiguating a collision --
    /// this unconditional-ness is what makes the format deterministic.
    private static func editionMarker(for input: NamingInput) -> String? {
        if let volume = input.volume?.trimmingCharacters(in: .whitespacesAndNewlines), !volume.isEmpty {
            return volume
        }
        return input.year.map(String.init)
    }

    /// Zero-pads the integer portion of an issue number to 3 digits ("1" -> "001", "1.1" ->
    /// "001.1"). Anything that isn't purely numeric (e.g. "1A", "Ashcan", "0.5AU") is left exactly
    /// as-is -- it can't be padded meaningfully, and forcing it would risk misrepresenting a real
    /// alternate-numbering scheme.
    private static func paddedIssueNumber(_ raw: String) -> String {
        if let dotIndex = raw.firstIndex(of: ".") {
            let intPart = String(raw[..<dotIndex])
            guard let n = Int(intPart) else { return raw }
            return String(format: "%03d", n) + raw[dotIndex...]
        }
        guard let n = Int(raw) else { return raw }
        return String(format: "%03d", n)
    }

    /// Exactly the fields idealFilename(...) needs per comic, plus an identity and enough
    /// context (year, volume, original path) to break ties deterministically when disambiguating.
    struct NamingInput {
        let id: Int64
        let series: String
        let issueNumber: String?
        let title: String
        let fileExtension: String
        let year: Int?
        let volume: String?
        let filePath: String
    }

    /// The part of `title` that isn't already implied by `base` (the bare filename minus
    /// extension) -- e.g. base "Robin (TPB)" + title "Robin v01 - Reborn" yields nil-overlap, so
    /// the whole title ("Robin v01 - Reborn") is a meaningful disambiguator; base "Batman Annual"
    /// + title "Batman Annual" yields nothing extra, so callers should fall back to year/index
    /// instead of a redundant, uninformative disambiguator.
    private static func titleHint(base: String, title: String) -> String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle.localizedCaseInsensitiveCompare(base) != .orderedSame else { return nil }
        if let range = trimmedTitle.range(of: base, options: [.caseInsensitive, .anchored]) {
            let remainder = trimmedTitle[range.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "-–— "))
            let unwrapped = unwrapFullyParenthesized(String(remainder))
            return unwrapped.isEmpty ? nil : unwrapped
        }
        return trimmedTitle
    }

    /// Strips a fully-enclosing "(...)" wrapper, repeatedly, until none remains. Without this, a
    /// `title` that's itself a previously-generated disambiguated filename (e.g. because a scan
    /// re-derived it from an already-renamed file on disk) gets its whole "(already a hint)"
    /// remainder handed straight back as a NEW hint -- which `idealFilename` then wraps in another
    /// layer of parens, compounding one extra "()" nesting level on every subsequent rename pass
    /// instead of converging to a stable name.
    private static func unwrapFullyParenthesized(_ s: String) -> String {
        var current = s
        while current.hasPrefix("("), current.hasSuffix(")") {
            var depth = 0
            var closesAtEnd = false
            for (offset, char) in current.enumerated() {
                if char == "(" { depth += 1 }
                else if char == ")" {
                    depth -= 1
                    if depth == 0 {
                        closesAtEnd = (offset == current.count - 1)
                        break
                    }
                }
            }
            guard closesAtEnd else { break }
            current = String(current.dropFirst().dropLast())
        }
        return current
    }

    /// Computes each input's canonical filename (always including its edition marker -- see the
    /// type-level doc comment), appending a further disambiguator to any name that would still
    /// collide with another input in the same call even with the edition marker included (e.g.
    /// two annuals from the same year with no other distinguishing info -- rare, but real).
    /// Without this last-resort tier, annuals/specials/TPBs that land on the identical edition
    /// marker all reduce to the same name via idealFilename(...) alone -- a caller that treats "would
    /// collide with another proposed rename" as fatal (as RenameFilesView does, to avoid two files
    /// racing for the same final name) ends up silently skipping every comic in the group instead
    /// of renaming any of them.
    ///
    /// Last-resort disambiguator preference (only reached when the edition marker alone didn't
    /// already separate the group): the distinguishing part of the comic's own `title` (e.g. a
    /// TPB's "v01 - Reborn" subtitle), then a running index.
    static func disambiguatedFilenames(for inputs: [NamingInput]) -> [Int64: String] {
        var result: [Int64: String] = [:]
        var byBareName: [String: [NamingInput]] = [:]
        for input in inputs {
            let bare = idealFilename(series: input.series, issueNumber: input.issueNumber,
                                      title: input.title, fileExtension: input.fileExtension,
                                      edition: editionMarker(for: input))
            byBareName[bare.lowercased(), default: []].append(input)
        }
        for group in byBareName.values {
            guard group.count > 1 else {
                let input = group[0]
                result[input.id] = idealFilename(series: input.series, issueNumber: input.issueNumber,
                                                  title: input.title, fileExtension: input.fileExtension,
                                                  edition: editionMarker(for: input))
                continue
            }
            // Deliberately NOT derived from `bareKey` (which includes the now-always-present
            // edition marker) -- titleHint needs to compare against the name MINUS edition/
            // disambiguator, or a title that's genuinely redundant with the series+suffix (e.g.
            // title "Batman Annual" for series "Batman") would stop being recognized as
            // redundant once the edition marker is appended to the comparison base, producing a
            // bogus hint that's just the whole title repeated back.
            let sample = group[0]
            let base = String(idealFilename(series: sample.series, issueNumber: sample.issueNumber,
                                             title: sample.title, fileExtension: sample.fileExtension)
                .dropLast(sample.fileExtension.count + 1))
            // Deterministic order (year, then original path) so re-running this over the same
            // library twice proposes the same disambiguated names, not whatever order the
            // caller's comics happened to be fetched in.
            let sorted = group.sorted {
                if $0.year != $1.year { return ($0.year ?? 0) < ($1.year ?? 0) }
                return $0.filePath < $1.filePath
            }
            var used = Set<String>()
            for input in sorted {
                let edition = editionMarker(for: input)
                // Only consult titleHint for no-issue-number entries (TPBs/collections, where a
                // title like "v01 - Reborn" is genuinely the only distinguishing info available).
                // For a numbered issue, the issue number is already supposed to be what
                // distinguishes it -- if two numbered issues still collide even with the edition
                // marker included, that's a genuine duplicate/reprint, and title text at that
                // point is unreliable: a title re-derived from a PREVIOUS rename pass's own output
                // (e.g. no ComicInfo.xml, so title == old filename) would otherwise get
                // misidentified as "new information" purely because its old, differently-padded
                // issue-number text doesn't literally match this pass's freshly zero-padded base,
                // re-wrapping a stale disambiguator instead of falling through to a clean index.
                let hasIssueNumber = !(input.issueNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hint = hasIssueNumber ? nil : titleHint(base: base, title: input.title)
                var disambiguator = hint
                var name = idealFilename(series: input.series, issueNumber: input.issueNumber,
                                          title: input.title, fileExtension: input.fileExtension,
                                          edition: edition, disambiguator: disambiguator)
                var attempt = 2
                while used.contains(name.lowercased()) {
                    disambiguator = [hint, "\(attempt)"].compactMap { $0 }.joined(separator: ", ")
                    name = idealFilename(series: input.series, issueNumber: input.issueNumber,
                                          title: input.title, fileExtension: input.fileExtension,
                                          edition: edition, disambiguator: disambiguator)
                    attempt += 1
                }
                used.insert(name.lowercased())
                result[input.id] = name
            }
        }
        return result
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

    /// The single entry point both callers that need real, ideal filenames use (the bulk Rename
    /// Files tool, and the single-comic "fix this filename" action): resolves canonical names per
    /// (publisher, series) group first, then disambiguates the whole batch. Kept in one place so
    /// the two-step composition can't drift between call sites.
    static func idealFilenames(for comics: [Comic]) -> [Int64: String] {
        let canonicalNames = canonicalSeriesNames(for: comics.map {
            (publisher: $0.publisher, series: $0.series, gcdSeriesName: $0.gcdSeriesName)
        })
        return disambiguatedFilenames(for: comics.map {
            let key = "\($0.publisher):\($0.series)"
            return NamingInput(
                id: $0.id, series: canonicalNames[key] ?? $0.gcdSeriesName ?? $0.series,
                issueNumber: $0.gcdIssueNumber ?? $0.issueNumber,
                title: $0.title, fileExtension: $0.fileExtension,
                year: $0.year, volume: $0.volume, filePath: $0.filePath
            )
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
