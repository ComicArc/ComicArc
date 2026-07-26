import Testing
import Foundation
@testable import ComicArc

final class MetadataConflictTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "MetadataConflictTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    @Test func upsertCreatesPendingConflict() throws {
        let id = try insertTestComic(into: db, series: "Old Series", publisher: "Marvel", issue: "1", title: "Old Series #1")
        db.upsertMetadataConflicts([
            .init(comicId: id, field: "series", current: "Old Series", proposed: "New Series", source: "ComicInfo.xml")
        ])

        let pending = db.pendingMetadataConflicts()
        #expect(pending.count == 1)
        let conflict = try #require(pending.first).conflict
        #expect(conflict.field == "series")
        #expect(conflict.currentValue == "Old Series")
        #expect(conflict.proposedValue == "New Series")
        #expect(conflict.status == "pending")
    }

    @Test func applyWritesProposedValueAndSetsMetaEdited() throws {
        let id = try insertTestComic(into: db, series: "Old Series", publisher: "Marvel", issue: "1", title: "Old Series #1")
        db.upsertMetadataConflicts([
            .init(comicId: id, field: "series", current: "Old Series", proposed: "New Series", source: "ComicInfo.xml")
        ])
        let conflictId = try #require(db.pendingMetadataConflicts().first).conflict.id

        db.resolveMetadataConflict(id: conflictId, apply: true)

        let comic = try #require(db.allComics(series: "New Series", sortOrder: .manual).first)
        #expect(comic.series == "New Series")
        #expect(db.pendingMetadataConflicts().isEmpty, "resolved conflict should no longer be pending")
    }

    @Test func dismissLeavesComicUnchanged() throws {
        let id = try insertTestComic(into: db, series: "Old Series", publisher: "Marvel", issue: "1", title: "Old Series #1")
        db.upsertMetadataConflicts([
            .init(comicId: id, field: "series", current: "Old Series", proposed: "New Series", source: "ComicInfo.xml")
        ])
        let conflictId = try #require(db.pendingMetadataConflicts().first).conflict.id

        db.resolveMetadataConflict(id: conflictId, apply: false)

        let comic = try #require(db.allComics(series: "Old Series", sortOrder: .manual).first)
        #expect(comic.series == "Old Series", "dismissing must never change the comic's current value")
        #expect(db.pendingMetadataConflicts().isEmpty)
    }

    @Test("Re-detecting a conflict with a new proposed value re-opens it, even if previously dismissed")
    func redetectReopensdismissedConflict() throws {
        let id = try insertTestComic(into: db, series: "Old Series", publisher: "Marvel", issue: "1", title: "Old Series #1")
        db.upsertMetadataConflicts([
            .init(comicId: id, field: "series", current: "Old Series", proposed: "New Series", source: "ComicInfo.xml")
        ])
        let firstId = try #require(db.pendingMetadataConflicts().first).conflict.id
        db.resolveMetadataConflict(id: firstId, apply: false)
        #expect(db.pendingMetadataConflicts().isEmpty)

        db.upsertMetadataConflicts([
            .init(comicId: id, field: "series", current: "Old Series", proposed: "Newer Series", source: "ComicInfo.xml")
        ])

        let pending = db.pendingMetadataConflicts()
        #expect(pending.count == 1, "re-detecting must update the existing (comic_id, field) row, not accumulate a duplicate")
        #expect(pending.first?.conflict.proposedValue == "Newer Series")
        #expect(pending.first?.conflict.status == "pending")
    }

    @Test func clearAllRemovesConflicts() throws {
        let id = try insertTestComic(into: db, series: "Old Series", publisher: "Marvel", issue: "1", title: "Old Series #1")
        db.upsertMetadataConflicts([
            .init(comicId: id, field: "series", current: "Old Series", proposed: "New Series", source: "ComicInfo.xml")
        ])
        #expect(db.pendingMetadataConflicts().count == 1)

        db.clearAll()

        #expect(db.pendingMetadataConflicts().isEmpty)
    }

    // MARK: - batchInsert's own conflict detection (a rescan proposing a different value)

    @Test("A rescan proposing a genuinely different, non-placeholder series value on an already-imported comic must not silently apply it -- it gets flagged instead")
    func rescanWithRealDisagreementIsFlaggedNotApplied() throws {
        db.batchInsert([DatabaseManager.ComicInsert(
            title: "Batman #1", filePath: "/tmp/batman1.cbz", publisher: "DC", character: nil,
            series: "Old Series", issueNumber: "1", pageCount: 20, writer: nil, penciller: nil,
            year: nil, storyArc: nil, languageIso: nil, fileHash: nil
        )])
        let id = try #require(db.allComics(series: "Old Series", sortOrder: .manual).first).id

        // Simulates a rescan of the same file whose ComicInfo.xml now resolves to a different series.
        db.batchInsert([DatabaseManager.ComicInsert(
            title: "Batman #1", filePath: "/tmp/batman1.cbz", publisher: "DC", character: nil,
            series: "New Series", issueNumber: "1", pageCount: 20, writer: nil, penciller: nil,
            year: nil, storyArc: nil, languageIso: nil, fileHash: nil,
            seriesSource: "ComicInfo.xml"
        )])

        let comic = try #require(db.allComics(series: "Old Series", sortOrder: .manual).first { $0.id == id })
        #expect(comic.series == "Old Series", "the real prior value must not be silently overwritten")
        let pending = db.pendingMetadataConflicts()
        #expect(pending.contains { $0.conflict.comicId == id && $0.conflict.field == "series" && $0.conflict.proposedValue == "New Series" })
    }

    @Test("A rescan filling in a placeholder (\"General\") with a real value must auto-apply, not be flagged as a conflict")
    func rescanFillingPlaceholderAutoApplies() throws {
        db.batchInsert([DatabaseManager.ComicInsert(
            title: "Batman #1", filePath: "/tmp/batman2.cbz", publisher: "DC", character: nil,
            series: "General", issueNumber: "1", pageCount: 20, writer: nil, penciller: nil,
            year: nil, storyArc: nil, languageIso: nil, fileHash: nil
        )])

        db.batchInsert([DatabaseManager.ComicInsert(
            title: "Batman #1", filePath: "/tmp/batman2.cbz", publisher: "DC", character: nil,
            series: "Batman", issueNumber: "1", pageCount: 20, writer: nil, penciller: nil,
            year: nil, storyArc: nil, languageIso: nil, fileHash: nil,
            seriesSource: "ComicInfo.xml"
        )])

        let comic = try #require(db.allComics(series: "Batman", sortOrder: .manual).first)
        #expect(comic.series == "Batman", "filling in a placeholder is a strict improvement, not a disagreement")
        #expect(db.pendingMetadataConflicts().isEmpty)
    }

    @Test("A manually-edited comic must never be touched by a rescan's proposal, and no conflict should be raised for a deliberate edit")
    func metaEditedComicIsUntouchedByRescanAndRaisesNoConflict() throws {
        db.batchInsert([DatabaseManager.ComicInsert(
            title: "Batman #1", filePath: "/tmp/batman3.cbz", publisher: "DC", character: nil,
            series: "Old Series", issueNumber: "1", pageCount: 20, writer: nil, penciller: nil,
            year: nil, storyArc: nil, languageIso: nil, fileHash: nil
        )])
        let id = try #require(db.allComics(series: "Old Series", sortOrder: .manual).first).id
        db.updateMeta(comicId: id, fields: [("series", "User Corrected Series")])

        db.batchInsert([DatabaseManager.ComicInsert(
            title: "Batman #1", filePath: "/tmp/batman3.cbz", publisher: "DC", character: nil,
            series: "Some Other Series", issueNumber: "1", pageCount: 20, writer: nil, penciller: nil,
            year: nil, storyArc: nil, languageIso: nil, fileHash: nil,
            seriesSource: "ComicInfo.xml"
        )])

        let comic = try #require(db.allComics(series: "User Corrected Series", sortOrder: .manual).first)
        #expect(comic.series == "User Corrected Series")
        #expect(db.pendingMetadataConflicts().isEmpty, "a deliberate user edit isn't ambiguous -- it must never raise a review conflict")
    }

    // MARK: - Existing-library import-priority audit plumbing
    // (the archive-reopening step itself lives in LibraryScanner, which is hardcoded to
    // DatabaseManager.shared with a private init() -- not test-isolable without a larger DB-
    // injection refactor. These tests cover the DatabaseManager-side logic the audit depends on.)

    @Test func pendingImportPriorityAuditPathsFindsOnlyRowsMissingTheMirror() throws {
        db.batchInsert([DatabaseManager.ComicInsert(
            title: "Needs Audit", filePath: "/tmp/needs-audit.cbz", publisher: "DC", character: nil,
            series: "Batman", issueNumber: "1", pageCount: 20, writer: nil, penciller: nil,
            year: nil, storyArc: nil, languageIso: nil, fileHash: nil, hasComicInfo: true
        )])
        // A comic with no ComicInfo.xml at all should never be selected -- there's nothing to audit.
        db.batchInsert([DatabaseManager.ComicInsert(
            title: "No ComicInfo", filePath: "/tmp/no-comicinfo.cbz", publisher: "DC", character: nil,
            series: "Batman", issueNumber: "2", pageCount: 20, writer: nil, penciller: nil,
            year: nil, storyArc: nil, languageIso: nil, fileHash: nil, hasComicInfo: false
        )])
        // A comic already migrated (mirror already populated) should never be re-selected.
        db.batchInsert([DatabaseManager.ComicInsert(
            title: "Already Migrated", filePath: "/tmp/already-migrated.cbz", publisher: "DC", character: nil,
            series: "Batman", issueNumber: "3", pageCount: 20, writer: nil, penciller: nil,
            year: nil, storyArc: nil, languageIso: nil, fileHash: nil, hasComicInfo: true,
            comicInfoSeries: "Batman"
        )])

        let pending = db.pendingImportPriorityAuditPaths()
        #expect(pending.count == 1)
        #expect(pending.first?.path == "/tmp/needs-audit.cbz")
    }

    @Test func updateComicInfoMirrorsWritesThroughWithoutTouchingProtectedFields() throws {
        let id = try insertTestComic(into: db, series: "Old Series", publisher: "Marvel", issue: "1", title: "Old Series #1")

        db.updateComicInfoMirrors([(id: id, comicInfoSeries: "Real Series", comicInfoPublisher: "Real Publisher")])

        let snapshot = try #require(db.identitySnapshots(for: [id])[id])
        #expect(snapshot.series == "Old Series", "the mirror write must never touch the protected primary column")
        #expect(db.pendingImportPriorityAuditPaths().isEmpty, "comicinfo_series is now populated, so this row is no longer pending")
    }

    @Test func auditCompletionGateIsIdempotent() {
        #expect(db.hasCompletedImportPriorityAudit() == false)
        db.markImportPriorityAuditComplete()
        #expect(db.hasCompletedImportPriorityAudit())
        // Marking it again must not error or duplicate the migrations row.
        db.markImportPriorityAuditComplete()
        #expect(db.hasCompletedImportPriorityAudit())
    }

    @Test("Migration gates track schema/data-migration history, not library content -- a factory reset must not reopen them, matching every other one-time migration in this file")
    func clearAllDoesNotResetTheAuditGate() {
        db.markImportPriorityAuditComplete()
        #expect(db.hasCompletedImportPriorityAudit())
        db.clearAll()
        #expect(db.hasCompletedImportPriorityAudit(), "clearAll wipes comics, not migration history -- newly-imported comics already get comicinfo_series correctly on first import, so nothing depends on re-running this")
    }
}
