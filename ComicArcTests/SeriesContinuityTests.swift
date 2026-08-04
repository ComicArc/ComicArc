import Testing
@testable import ComicArc

struct SeriesContinuityTests {
    // MARK: - proposeLinks

    @Test func proposeLinksResolvesUnambiguousBond() {
        let bonds = [GCDSeriesBond(originName: "Tales of Suspense", originPublisher: "Marvel",
                                    targetName: "Captain America", targetPublisher: "Marvel")]
        let library = [
            SeriesContinuity.LibrarySeries(publisher: "Marvel", series: "Tales of Suspense"),
            SeriesContinuity.LibrarySeries(publisher: "Marvel", series: "Captain America"),
        ]
        let proposals = SeriesContinuity.proposeLinks(bonds: bonds, librarySeries: library)
        #expect(proposals.count == 1)
        #expect(proposals.first?.parent.series == "Tales of Suspense")
        #expect(proposals.first?.child.series == "Captain America")
    }

    @Test("A bond whose target name matches more than one library series (e.g. a duplicate folder-derived entry sharing a display name) is refused, not guessed")
    func proposeLinksRefusesAmbiguousMatch() {
        let bonds = [GCDSeriesBond(originName: "Tales of Suspense", originPublisher: "Marvel",
                                    targetName: "Captain America", targetPublisher: "Marvel")]
        let library = [
            SeriesContinuity.LibrarySeries(publisher: "Marvel", series: "Tales of Suspense"),
            SeriesContinuity.LibrarySeries(publisher: "Marvel", series: "Captain America"),
            // Normalizes to the same name as the entry above (case-insensitive) -- makes the
            // target ambiguous between two distinct local series.
            SeriesContinuity.LibrarySeries(publisher: "Marvel", series: "captain america"),
        ]
        let proposals = SeriesContinuity.proposeLinks(bonds: bonds, librarySeries: library)
        #expect(proposals.isEmpty)
    }

    @Test func proposeLinksSkipsBondWithNoMatchingTarget() {
        let bonds = [GCDSeriesBond(originName: "Amazing Spider-Man", originPublisher: "Marvel",
                                    targetName: "Totally Unrelated Series", targetPublisher: "Marvel")]
        let library = [
            SeriesContinuity.LibrarySeries(publisher: "Marvel", series: "Amazing Spider-Man"),
            SeriesContinuity.LibrarySeries(publisher: "Marvel", series: "Superior Spider-Man"),
        ]
        #expect(SeriesContinuity.proposeLinks(bonds: bonds, librarySeries: library).isEmpty)
    }

    @Test func proposeLinksRequiresAtLeastTwoLibrarySeries() {
        let bonds = [GCDSeriesBond(originName: "A", originPublisher: "Marvel", targetName: "B", targetPublisher: "Marvel")]
        let library = [SeriesContinuity.LibrarySeries(publisher: "Marvel", series: "A")]
        #expect(SeriesContinuity.proposeLinks(bonds: bonds, librarySeries: library).isEmpty)
    }

    // MARK: - findCycles

    @Test func findCyclesDetectsTwoNodeCycle() {
        let links: [(parentKey: String, childKey: String)] = [
            ("Marvel:X:", "Marvel:Y:"),
            ("Marvel:Y:", "Marvel:X:"),
        ]
        let cycles = SeriesContinuity.findCycles(links: links)
        #expect(cycles.isEmpty == false)
    }

    @Test func findCyclesDetectsThreeNodeCycle() {
        let links: [(parentKey: String, childKey: String)] = [
            ("Marvel:A:", "Marvel:B:"),
            ("Marvel:B:", "Marvel:C:"),
            ("Marvel:C:", "Marvel:A:"),
        ]
        let cycles = SeriesContinuity.findCycles(links: links)
        #expect(cycles.isEmpty == false)
    }

    @Test func findCyclesReturnsNoneForValidChain() {
        let links: [(parentKey: String, childKey: String)] = [
            ("Marvel:A:", "Marvel:B:"),
            ("Marvel:B:", "Marvel:C:"),
        ]
        #expect(SeriesContinuity.findCycles(links: links).isEmpty)
    }

    // MARK: - chainOffsets

    @Test func chainOffsetsProducesIncreasingOffsetsOnThreeHopChain() throws {
        let links: [(parentKey: String, childKey: String)] = [
            ("Marvel:A:", "Marvel:B:"),
            ("Marvel:B:", "Marvel:C:"),
        ]
        let idsBySeriesKey: [String: [Int64]] = [
            "Marvel:A:": [1], "Marvel:B:": [2], "Marvel:C:": [3],
        ]
        let positions: [Int64: Int] = [1: 100, 2: 50, 3: 20]

        let offsets = SeriesContinuity.chainOffsets(links: links, idsBySeriesKey: idsBySeriesKey, positions: positions)

        #expect(offsets[1] == 0, "the root gets no offset")
        let aFinal = try #require(positions[1]) + (offsets[1] ?? 0)
        let bFinal = try #require(positions[2]) + (offsets[2] ?? 0)
        let cFinal = try #require(positions[3]) + (offsets[3] ?? 0)
        #expect(aFinal < bFinal)
        #expect(bFinal < cFinal)
    }

    @Test func chainOffsetsEmptyForNoLinks() {
        #expect(SeriesContinuity.chainOffsets(links: [], idsBySeriesKey: [:], positions: [:]).isEmpty)
    }
}
