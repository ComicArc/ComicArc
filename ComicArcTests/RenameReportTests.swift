import Testing
@testable import ComicArc

struct RenameReportTests {

    @Test func allZeroWhenNothingHappened() {
        let report = RenameReport.summarize(succeeded: 0, unchanged: 0, skipped: 0, failedStaging: [], failedFinal: [])
        #expect(report.succeeded == 0)
        #expect(report.unchanged == 0)
        #expect(report.skipped == 0)
        #expect(report.totalFailed == 0)
    }

    @Test func succeededAndUnchangedAndSkippedCountedIndependently() {
        let report = RenameReport.summarize(succeeded: 5, unchanged: 3, skipped: 2, failedStaging: [], failedFinal: [])
        #expect(report.succeeded == 5)
        #expect(report.unchanged == 3)
        #expect(report.skipped == 2)
        #expect(report.totalFailed == 0)
    }

    @Test func totalFailedSumsStagingAndFinalFailures() {
        let staging = [RenameFailure(name: "a.cbz", reason: "Couldn't move the file: permission denied")]
        let final = [
            RenameFailure(name: "b.cbz", reason: "Another file already exists with the target name"),
            RenameFailure(name: "c.cbz", reason: "Rename failed: disk full"),
        ]
        let report = RenameReport.summarize(succeeded: 1, unchanged: 0, skipped: 0, failedStaging: staging, failedFinal: final)
        #expect(report.totalFailed == 3)
        #expect(report.failedStaging.count == 1)
        #expect(report.failedFinal.count == 2)
    }

    @Test func failureReasonsAreKeptDistinctPerFile() {
        let staging = [RenameFailure(name: "a.cbz", reason: "staging failed")]
        let final = [RenameFailure(name: "b.cbz", reason: "final failed")]
        let report = RenameReport.summarize(succeeded: 0, unchanged: 0, skipped: 0, failedStaging: staging, failedFinal: final)
        #expect(report.failedStaging.first?.reason == "staging failed")
        #expect(report.failedFinal.first?.reason == "final failed")
    }
}
