import Testing
import Foundation
@testable import ComicArc

/// Covers the database side of peer sync -- `progressSyncSnapshot`/`applySyncedProgress` -- which
/// is where the actual correctness risk lives (last-write-wins merge across two independent
/// databases). The networking layer (PeerSyncService/MultipeerConnectivity) is exercised by hand
/// against two real devices, same as this project's other hardware-dependent code; nothing here
/// touches the network.
final class PeerSyncTests {
    private let db: DatabaseManager
    private let tempPath: String

    init() {
        (db, tempPath) = makeTestDatabase(name: "PeerSyncTests")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    @Test func snapshotOnlyIncludesStartedComicsWithAFileHash() throws {
        let started = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                                          title: "Batman #1", fileHash: "hash-1")
        db.updateProgress(comicId: started, page: 5)

        // Untouched comic -- never opened, shouldn't appear in a progress sync payload at all.
        _ = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "2",
                                title: "Batman #2", fileHash: "hash-2")

        // No file hash yet (e.g. hashing still pending) -- can't be matched on the other device.
        let noHash = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "3",
                                         title: "Batman #3", fileHash: nil)
        db.updateProgress(comicId: noHash, page: 2)

        let snapshot = db.progressSyncSnapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.fileHash == "hash-1")
        #expect(snapshot.first?.progress == 5)
    }

    @Test func appliesIncomingProgressWhenNoLocalProgressExists() throws {
        let id = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                                     title: "Batman #1", fileHash: "hash-1")

        let count = db.applySyncedProgress([(fileHash: "hash-1", progress: 10, lastRead: "2026-08-01 10:00:00")])

        #expect(count == 1)
        let comic = try #require(db.comic(id: id))
        #expect(comic.progress == 10)
    }

    @Test("The core safety property: a newer local read must never be clobbered by an older incoming one")
    func neverOverwritesNewerLocalProgressWithOlderIncoming() throws {
        let id = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                                     title: "Batman #1", fileHash: "hash-1")
        db.updateProgress(comicId: id, page: 20) // stamps last_read = now, i.e. "later" than anything from 2020

        let count = db.applySyncedProgress([(fileHash: "hash-1", progress: 3, lastRead: "2020-01-01 10:00:00")])

        #expect(count == 0, "an older incoming read must be skipped, not applied")
        let comic = try #require(db.comic(id: id))
        #expect(comic.progress == 20, "local, newer progress must survive untouched")
    }

    @Test func appliesNewerIncomingProgressOverOlderLocal() throws {
        let id = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                                     title: "Batman #1", fileHash: "hash-1")
        _ = db.exec("""
            INSERT INTO reading_progress (comic_id, current_page, last_read) VALUES (\(id), 3, '2020-01-01 10:00:00')
            """)

        let count = db.applySyncedProgress([(fileHash: "hash-1", progress: 30, lastRead: "2026-08-01 10:00:00")])

        #expect(count == 1)
        let comic = try #require(db.comic(id: id))
        #expect(comic.progress == 30)
    }

    @Test func skipsComicsNotPresentInThisLibrary() throws {
        _ = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1",
                                title: "Batman #1", fileHash: "hash-1")

        // "unknown-hash" doesn't exist on this device at all -- must be silently skipped, not an error.
        let count = db.applySyncedProgress([(fileHash: "unknown-hash", progress: 10, lastRead: "2026-08-01 10:00:00")])

        #expect(count == 0)
    }

    @Test func handlesMultipleIncomingItemsIndependently() throws {
        let a = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "1", title: "Batman #1", fileHash: "hash-a")
        let b = try insertTestComic(into: db, series: "Batman", publisher: "DC", issue: "2", title: "Batman #2", fileHash: "hash-b")
        db.updateProgress(comicId: b, page: 15) // b has newer local progress than the incoming update below

        let count = db.applySyncedProgress([
            (fileHash: "hash-a", progress: 7, lastRead: "2026-08-01 10:00:00"),
            (fileHash: "hash-b", progress: 1, lastRead: "2020-01-01 10:00:00"),
        ])

        #expect(count == 1, "only hash-a should apply; hash-b's incoming read is older than local")
        let comicA = try #require(db.comic(id: a))
        let comicB = try #require(db.comic(id: b))
        #expect(comicA.progress == 7)
        #expect(comicB.progress == 15)
    }
}
