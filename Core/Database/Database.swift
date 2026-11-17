import Foundation
import SQLite3
import os

private let log = Logger(subsystem: "com.comicarc", category: "database")
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum AppPaths {
    static let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ComicArc", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var database: URL { dataDirectory.appendingPathComponent("comics.db") }
    static var covers: URL {
        let dir = dataDirectory.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// The library database. Writes go through one connection and reads through another (WAL mode),
/// so browsing never waits behind a scan or import. Each connection lives on its own serial queue.
final class Database: @unchecked Sendable {
    static let shared = Database(url: AppPaths.database)

    let url: URL
    private var writer: SQLiteConnection!
    private var reader: SQLiteConnection!
    private let writeQueue = DispatchQueue(label: "com.comicarc.db.write", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "com.comicarc.db.read", qos: .userInitiated)
    var backupURL: URL { URL(fileURLWithPath: url.path + ".bak") }

    init(url: URL) {
        self.url = url
        openConnections()
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.refreshBackup() }
    }

    // MARK: - Access

    func read<T>(_ body: @escaping (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            readQueue.async { cont.resume(with: Result { try body(self.reader) }) }
        }
    }

    @discardableResult
    func write<T>(_ body: @escaping (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            writeQueue.async { cont.resume(with: Result { try body(self.writer) }) }
        }
    }

    /// Blocking variants for code already running off the main thread (scanner, intents).
    func readSync<T>(_ body: (SQLiteConnection) throws -> T) throws -> T { try readQueue.sync { try body(reader) } }
    @discardableResult
    func writeSync<T>(_ body: (SQLiteConnection) throws -> T) throws -> T { try writeQueue.sync { try body(writer) } }

    // MARK: - Lifecycle

    private func openConnections() {
        do {
            writer = try SQLiteConnection(path: url.path, readOnly: false)
            try configure(writer)
        } catch {
            // Only an unopenable file is set aside; the library is rebuilt by the next scan.
            log.fault("Database can't be opened: \(String(describing: error))")
            setAside()
            writer = try! SQLiteConnection(path: url.path, readOnly: false)
            try! configure(writer)
        }
        do {
            // Restore only on a real integrity failure, never because the check itself errored.
            if let check = try? writer.scalarString("PRAGMA quick_check"), check != "ok" { try restoreFromBackup() }
            try Schema.create(on: writer)
        } catch {
            log.fault("Database setup failed: \(String(describing: error))")
        }
        reader = (try? SQLiteConnection(path: url.path, readOnly: true)) ?? writer
        if reader !== writer {
            try? reader.execute("PRAGMA query_only = ON")
            registerFunctions(reader)
        }
    }

    private func setAside() {
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.moveItem(atPath: url.path + suffix, toPath: url.path + ".unreadable-\(stamp)" + suffix)
        }
    }

    private func configure(_ c: SQLiteConnection) throws {
        try c.execute("PRAGMA journal_mode = WAL")
        try c.execute("PRAGMA synchronous = NORMAL")
        try c.execute("PRAGMA foreign_keys = ON")
        try c.execute("PRAGMA temp_store = MEMORY")
        registerFunctions(c)
    }

    private func restoreFromBackup() throws {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return }
        log.error("Integrity check failed; restoring from backup")
        writer = nil
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(atPath: url.path + "-wal")
        try? fm.removeItem(atPath: url.path + "-shm")
        try fm.copyItem(at: backupURL, to: url)
        writer = try SQLiteConnection(path: url.path, readOnly: false)
        try configure(writer)
    }

    /// Snapshot used for corruption recovery. Runs at launch and after each scan.
    func refreshBackup() {
        writeQueue.sync {
            do {
                try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                try? FileManager.default.removeItem(at: backupURL)
                try writer.run("VACUUM INTO ?", [backupURL.path])
            } catch {
                log.error("Backup failed: \(String(describing: error))")
            }
        }
    }

    /// Flushes the WAL so the main database file is complete (on quit).
    func checkpoint() {
        writeQueue.sync { try? writer.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
    }

    // MARK: - SQL functions

    /// `comic_type(issue, title, series, format)` and `is_special_issue(issue, title, series)`, so
    /// sorting and health checks can use the same classification rules as Swift code.
    private func registerFunctions(_ c: SQLiteConnection) {
        let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC
        sqlite3_create_function_v2(c.handle, "is_special_issue", 3, flags, nil, { ctx, _, argv in
            let special = ComicClassifier.isSpecial(issueNumber: sqlText(argv, 0), title: sqlText(argv, 1) ?? "")
            sqlite3_result_int(ctx, special ? 1 : 0)
        }, nil, nil, nil)
        sqlite3_create_function_v2(c.handle, "comic_type", 4, flags, nil, { ctx, _, argv in
            let type = ComicClassifier.classify(issueNumber: sqlText(argv, 0), title: sqlText(argv, 1) ?? "",
                                                format: sqlText(argv, 3))
            sqlite3_result_text(ctx, type.rawValue, -1, SQLITE_TRANSIENT)
        }, nil, nil, nil)
    }
}

private func sqlText(_ argv: UnsafeMutablePointer<OpaquePointer?>?, _ i: Int) -> String? {
    guard let argv, let value = argv[i], let p = sqlite3_value_text(value) else { return nil }
    return String(cString: p)
}
