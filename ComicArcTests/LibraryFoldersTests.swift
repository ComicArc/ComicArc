import Testing
import Foundation
@testable import ComicArc

/// Uses an isolated `UserDefaults` suite (never `.standard`) so these tests can never read or
/// mutate the real app's actual configured library folders.
final class LibraryFoldersTests {
    private let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        suiteName = "LibraryFoldersTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func encodeDecodeRoundTripsArbitraryPaths() {
        // Unix paths can legally contain commas -- this is exactly why JSON, not comma-joining,
        // is the correct encoding here.
        let paths = ["/Users/me/Comics, Vol 1", "/Volumes/NAS/More Comics"]
        #expect(LibraryFolders.decode(LibraryFolders.encode(paths)) == paths)
    }

    @Test func decodeReturnsEmptyForGarbageInput() {
        #expect(LibraryFolders.decode("not json").isEmpty)
        #expect(LibraryFolders.decode("").isEmpty)
    }

    @Test func readMigratingReturnsEmptyWhenNothingConfigured() {
        #expect(LibraryFolders.readMigrating(defaults: defaults).isEmpty)
    }

    @Test("The core guarantee: an existing install's single pre-multi-folder library path must survive as a one-element array, or updating would silently wipe an already-configured library and force the user back through onboarding")
    func readMigratingSeedsFromLegacySinglePathExactlyOnce() {
        defaults.set("/Users/me/Comics", forKey: LibraryFolders.legacySingleKey)

        let first = LibraryFolders.readMigrating(defaults: defaults)
        #expect(first == ["/Users/me/Comics"])

        // Confirm it actually persisted the migration (not just returned it transiently) by
        // checking the new key directly, then verify a second read is stable and doesn't
        // re-migrate or duplicate anything even if the legacy key is still sitting there.
        #expect(LibraryFolders.decode(defaults.string(forKey: LibraryFolders.key) ?? "") == ["/Users/me/Comics"])
        let second = LibraryFolders.readMigrating(defaults: defaults)
        #expect(second == ["/Users/me/Comics"])
    }

    @Test("Once the new array has real content, the legacy single path must never be consulted again -- otherwise removing a folder via the new multi-folder UI down to a DIFFERENT single folder would be silently overridden back to the stale legacy value")
    func readMigratingNeverOverridesANonEmptyArrayWithLegacyValue() {
        defaults.set("/Users/me/OldComics", forKey: LibraryFolders.legacySingleKey)
        LibraryFolders.write(["/Users/me/NewComics"], defaults: defaults)

        #expect(LibraryFolders.readMigrating(defaults: defaults) == ["/Users/me/NewComics"])
    }

    @Test func writeThenReadRoundTripsMultipleFolders() {
        let paths = ["/Users/me/Comics", "/Volumes/NAS/Comics"]
        LibraryFolders.write(paths, defaults: defaults)
        #expect(LibraryFolders.readMigrating(defaults: defaults) == paths)
    }

    @Test func readMigratingIgnoresEmptyLegacyValue() {
        defaults.set("", forKey: LibraryFolders.legacySingleKey)
        #expect(LibraryFolders.readMigrating(defaults: defaults).isEmpty)
    }
}
