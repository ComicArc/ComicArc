import Testing
@testable import ComicArc

struct ComicIdentityResolverTests {
    @Test("ComicInfo.xml wins regardless of folder, when present")
    func comicInfoWinsOverFolder() {
        let resolved = ComicIdentityResolver.resolve(.init(
            comicInfoSeries: "The Amazing Spider-Man", comicInfoPublisher: "Marvel",
            comicInfoIssueNumber: "441",
            folderSeries: "ASM (1963)", folderPublisher: "marvel-comics",
            filenameIssueNumber: "1"
        ))
        #expect(resolved.series == "The Amazing Spider-Man")
        #expect(resolved.publisher == "Marvel")
        #expect(resolved.issueNumber == "441")
        #expect(resolved.seriesSource == ComicIdentityResolver.comicInfoSource)
        #expect(resolved.publisherSource == ComicIdentityResolver.comicInfoSource)
        #expect(resolved.issueNumberSource == ComicIdentityResolver.comicInfoSource)
    }

    @Test("Folder/filename win when ComicInfo.xml is absent")
    func folderWinsWhenComicInfoAbsent() {
        let resolved = ComicIdentityResolver.resolve(.init(
            comicInfoSeries: nil, comicInfoPublisher: nil, comicInfoIssueNumber: nil,
            folderSeries: "ASM (1963)", folderPublisher: "Marvel",
            filenameIssueNumber: "441"
        ))
        #expect(resolved.series == "ASM (1963)")
        #expect(resolved.publisher == "Marvel")
        #expect(resolved.issueNumber == "441")
        #expect(resolved.seriesSource == ComicIdentityResolver.folderSource)
        #expect(resolved.publisherSource == ComicIdentityResolver.folderSource)
        #expect(resolved.issueNumberSource == ComicIdentityResolver.filenameSource)
    }

    @Test("Falls back to defaults when nothing is available")
    func fallsBackToDefaultsWhenNothingAvailable() {
        let resolved = ComicIdentityResolver.resolve(.init(
            comicInfoSeries: nil, comicInfoPublisher: nil, comicInfoIssueNumber: nil,
            folderSeries: nil, folderPublisher: nil, filenameIssueNumber: nil
        ))
        #expect(resolved.series == "General")
        #expect(resolved.publisher == "Unknown")
        #expect(resolved.issueNumber == nil)
        #expect(resolved.seriesSource == ComicIdentityResolver.defaultSource)
        #expect(resolved.publisherSource == ComicIdentityResolver.defaultSource)
        #expect(resolved.issueNumberSource == ComicIdentityResolver.defaultSource)
    }

    @Test("Empty-string ComicInfo values are treated the same as nil, not as a real value")
    func emptyComicInfoValuesFallThrough() {
        let resolved = ComicIdentityResolver.resolve(.init(
            comicInfoSeries: "   ", comicInfoPublisher: "", comicInfoIssueNumber: "",
            folderSeries: "ASM (1963)", folderPublisher: "Marvel",
            filenameIssueNumber: "441"
        ))
        #expect(resolved.series == "ASM (1963)")
        #expect(resolved.publisher == "Marvel")
        #expect(resolved.issueNumber == "441")
    }

    @Test("Each field resolves independently -- ComicInfo can win for one field while folder wins for another")
    func fieldsResolveIndependently() {
        let resolved = ComicIdentityResolver.resolve(.init(
            comicInfoSeries: "The Amazing Spider-Man", comicInfoPublisher: nil, comicInfoIssueNumber: nil,
            folderSeries: "ASM (1963)", folderPublisher: "Marvel",
            filenameIssueNumber: "441"
        ))
        #expect(resolved.series == "The Amazing Spider-Man")
        #expect(resolved.seriesSource == ComicIdentityResolver.comicInfoSource)
        #expect(resolved.publisher == "Marvel")
        #expect(resolved.publisherSource == ComicIdentityResolver.folderSource)
        #expect(resolved.issueNumber == "441")
        #expect(resolved.issueNumberSource == ComicIdentityResolver.filenameSource)
    }
}
