import Foundation

/// Series Continuity: resolves which publication run(s) a comic's identity belongs to, and chains
/// relaunches of the "same" series (across volume restarts) into one continuous publication
/// history -- generically, driven by GCD's own bond data, never hardcoded per publisher. Pure
/// graph logic with no SQLite of its own; `DatabaseManager` is the thin I/O glue around it (fetch
/// rows, call this, write results).
enum SeriesContinuity {
    struct LibrarySeries: Hashable {
        let publisher: String
        let series: String
    }

    struct ProposedLink: Equatable {
        let parent: LibrarySeries
        let child: LibrarySeries
    }

    /// Resolves each GCD bond to a unique library series pair. Refuses (drops) any bond whose
    /// origin or target name+publisher matches more than one library series -- the same
    /// refuse-on-ambiguous-tie principle `OfflineMetadataStore`'s own match scoring uses, applied
    /// here at the linking layer: a bond that could plausibly point at two different local series
    /// is safer left unlinked than guessed.
    static func proposeLinks(bonds: [GCDSeriesBond], librarySeries: [LibrarySeries]) -> [ProposedLink] {
        guard librarySeries.count > 1 else { return [] }

        func resolve(gcdName: String, gcdPublisher: String) -> LibrarySeries? {
            let candidates = librarySeries.filter {
                OfflineMetadataStore.seriesNamesMatch(local: $0.series, gcdName: gcdName) &&
                OfflineMetadataStore.normalizePublisher($0.publisher) == OfflineMetadataStore.normalizePublisher(gcdPublisher)
            }
            return candidates.count == 1 ? candidates.first : nil
        }

        var proposals: [ProposedLink] = []
        for bond in bonds {
            guard let origin = resolve(gcdName: bond.originName, gcdPublisher: bond.originPublisher),
                  let target = resolve(gcdName: bond.targetName, gcdPublisher: bond.targetPublisher),
                  origin != target else { continue }
            proposals.append(ProposedLink(parent: origin, child: target))
        }
        return proposals
    }

    /// Pure cycle detection over parent->child edges, keyed by "publisher:series:volume". A cycle
    /// existing at all means the link graph is broken (a series can't be its own ancestor) --
    /// `DatabaseManager.breakSeriesLinkCycles()` uses this to find and remove the offending link.
    static func findCycles(links: [(parentKey: String, childKey: String)]) -> [[String]] {
        var parentOf: [String: String] = [:]
        for link in links { parentOf[link.childKey] = link.parentKey }

        var cycles: [[String]] = []
        var globallySeen: Set<String> = []
        for start in parentOf.keys where !globallySeen.contains(start) {
            var path: [String] = []
            var indexInPath: [String: Int] = [:]
            var current = start
            while !globallySeen.contains(current) {
                if let cycleStart = indexInPath[current] {
                    cycles.append(Array(path[cycleStart...]))
                    break
                }
                indexInPath[current] = path.count
                path.append(current)
                guard let next = parentOf[current] else { break }
                current = next
            }
            globallySeen.formUnion(path)
        }
        return cycles
    }

    /// Per-id position offset so a child series' Publication Timeline positions land strictly
    /// after its parent's (and grandchildren after that, transitively) -- a continuous chain of
    /// relaunches reads as one uninterrupted history, not several independently-numbered ones.
    /// `positions` are each id's already-computed within-its-own-series position; this returns the
    /// additive offset to apply per id, rather than mutating positions directly, so the caller
    /// decides how/when to apply it.
    static func chainOffsets(
        links: [(parentKey: String, childKey: String)],
        idsBySeriesKey: [String: [Int64]],
        positions: [Int64: Int]
    ) -> [Int64: Int] {
        guard !links.isEmpty else { return [:] }

        var childrenOf: [String: [String]] = [:]
        var parentOf: [String: String] = [:]
        for link in links {
            childrenOf[link.parentKey, default: []].append(link.childKey)
            parentOf[link.childKey] = link.parentKey
        }
        let allKeys = Set(parentOf.keys).union(parentOf.values)
        let roots = allKeys.subtracting(parentOf.keys)

        var offsets: [Int64: Int] = [:]
        var visited: Set<String> = []

        func walk(_ seriesKey: String, baseOffset: Int) {
            guard !visited.contains(seriesKey) else { return }
            visited.insert(seriesKey)
            var maxPos = baseOffset
            for id in idsBySeriesKey[seriesKey] ?? [] where positions[id] != nil {
                offsets[id] = baseOffset
                maxPos = max(maxPos, positions[id]! + baseOffset)
            }
            // A full 1,000,000-stride buffer between parent and child, not just "one past the
            // parent's max" -- leaves interpolation room for anything placed relative to the
            // child's own first issue later, the same way adjacent mainline issues already do.
            for child in childrenOf[seriesKey] ?? [] { walk(child, baseOffset: maxPos + 1_000_000) }
        }
        for root in roots { walk(root, baseOffset: 0) }
        return offsets
    }
}
