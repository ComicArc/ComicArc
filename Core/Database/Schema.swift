import Foundation

/// The library schema. Identical to what earlier versions wrote, so an existing `comics.db` opens
/// unchanged; a new install gets the same tables directly.
enum Schema {
    static func create(on db: SQLiteConnection) throws {
        try db.execute(tables)
        try db.execute(indexes)
        try runMigrations(on: db)
    }

    /// Future schema changes go here, each applied once and recorded in `migrations`.
    private static let migrations: [(name: String, sql: String)] = []

    private static func runMigrations(on db: SQLiteConnection) throws {
        let applied = Set(try db.query("SELECT name FROM migrations") { $0.string(0) ?? "" })
        for m in migrations where !applied.contains(m.name) {
            try db.transaction {
                try db.execute(m.sql)
                try db.run("INSERT INTO migrations (name) VALUES (?)", [m.name])
            }
        }
    }

    private static let tables = """
    CREATE TABLE IF NOT EXISTS comics (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        title        TEXT NOT NULL,
        file_path    TEXT UNIQUE NOT NULL,
        publisher    TEXT,
        character    TEXT,
        series       TEXT,
        issue_number TEXT,
        page_count   INTEGER DEFAULT 0,
        added_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        position     INTEGER,
        writer       TEXT,
        penciller    TEXT,
        year         INTEGER,
        story_arc    TEXT,
        language_iso TEXT,
        deleted_at   TIMESTAMP,
        notes        TEXT,
        file_hash    TEXT,
        meta_edited INTEGER NOT NULL DEFAULT 0, cover_month INTEGER, alternate_number TEXT,
        story_arc_number TEXT, cover_day INTEGER, series_group TEXT, comicinfo_issue_number TEXT,
        volume TEXT, format TEXT, has_comicinfo INTEGER, scan_retry_count INTEGER NOT NULL DEFAULT 0,
        comicinfo_series TEXT, comicinfo_publisher TEXT, folder_series TEXT, folder_publisher TEXT,
        folder_group TEXT, trashed_file_path TEXT, deleted_reason TEXT
    );
    CREATE TABLE IF NOT EXISTS favorites (comic_id INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE);
    CREATE TABLE IF NOT EXISTS tags (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL, category TEXT);
    CREATE TABLE IF NOT EXISTS comic_tags (
        comic_id INTEGER REFERENCES comics(id) ON DELETE CASCADE,
        tag_id   INTEGER REFERENCES tags(id)   ON DELETE CASCADE,
        PRIMARY KEY (comic_id, tag_id)
    );
    CREATE TABLE IF NOT EXISTS runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, description TEXT, buy_link TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, position INTEGER, cover_image_path TEXT
    );
    CREATE TABLE IF NOT EXISTS run_items (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        run_id   INTEGER REFERENCES runs(id)   ON DELETE CASCADE,
        comic_id INTEGER REFERENCES comics(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        notes    TEXT DEFAULT '',
        UNIQUE(run_id, comic_id)
    );
    CREATE TABLE IF NOT EXISTS bookmarks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        comic_id INTEGER REFERENCES comics(id) ON DELETE CASCADE,
        page INTEGER NOT NULL, label TEXT DEFAULT '', created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        UNIQUE(comic_id, page)
    );
    CREATE TABLE IF NOT EXISTS reading_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        comic_id INTEGER REFERENCES comics(id) ON DELETE CASCADE,
        page_start INTEGER NOT NULL DEFAULT 0, page_end INTEGER NOT NULL DEFAULT 0,
        read_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    CREATE TABLE IF NOT EXISTS reading_goals (year INTEGER PRIMARY KEY, goal_count INTEGER NOT NULL DEFAULT 52);
    CREATE TABLE IF NOT EXISTS series_covers (
        series TEXT NOT NULL, publisher TEXT NOT NULL,
        comic_id INTEGER REFERENCES comics(id) ON DELETE SET NULL, image_path TEXT,
        PRIMARY KEY (series, publisher)
    );
    CREATE TABLE IF NOT EXISTS series_reader_prefs (
        series TEXT NOT NULL, publisher TEXT NOT NULL, fit_mode TEXT NOT NULL, rtl INTEGER NOT NULL,
        double_spread INTEGER NOT NULL, scroll_mode INTEGER NOT NULL,
        PRIMARY KEY (series, publisher)
    );
    CREATE TABLE IF NOT EXISTS character_covers (
        group_name TEXT NOT NULL, publisher TEXT NOT NULL, image_path TEXT NOT NULL,
        PRIMARY KEY (group_name, publisher)
    );
    CREATE TABLE IF NOT EXISTS series_order (
        group_name TEXT NOT NULL, publisher TEXT NOT NULL, series TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (group_name, publisher, series)
    );
    CREATE TABLE IF NOT EXISTS character_order (
        group_name TEXT NOT NULL, publisher TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (group_name, publisher)
    );
    CREATE TABLE IF NOT EXISTS publisher_order (publisher TEXT PRIMARY KEY, position INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS reading_order_overrides (
        comic_id INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE,
        position INTEGER NOT NULL, reason TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS metadata_conflicts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        comic_id INTEGER NOT NULL REFERENCES comics(id) ON DELETE CASCADE,
        field TEXT NOT NULL CHECK(field IN ('series','publisher','issue_number')),
        current_value TEXT, proposed_value TEXT, proposed_source TEXT NOT NULL,
        detected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','applied','dismissed')),
        resolved_at TIMESTAMP,
        UNIQUE(comic_id, field)
    );
    CREATE TABLE IF NOT EXISTS reading_progress (
        comic_id INTEGER PRIMARY KEY REFERENCES comics(id) ON DELETE CASCADE,
        current_page INTEGER DEFAULT 0, last_read TIMESTAMP DEFAULT CURRENT_TIMESTAMP, finished_at TIMESTAMP
    );
    """

    private static let indexes = """
    CREATE INDEX IF NOT EXISTS idx_comics_publisher ON comics(publisher);
    CREATE INDEX IF NOT EXISTS idx_comics_series ON comics(series);
    CREATE INDEX IF NOT EXISTS idx_comics_pub_series ON comics(publisher, series) WHERE deleted_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_comics_deleted ON comics(deleted_at) WHERE deleted_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_comics_file_hash ON comics(file_hash);
    CREATE INDEX IF NOT EXISTS idx_comics_position ON comics(position) WHERE deleted_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_comics_character ON comics(character) WHERE deleted_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_comic_tags_comic_id ON comic_tags(comic_id);
    CREATE INDEX IF NOT EXISTS idx_comic_tags_tag_id ON comic_tags(tag_id);
    CREATE INDEX IF NOT EXISTS idx_run_items_run_id ON run_items(run_id);
    CREATE INDEX IF NOT EXISTS idx_run_items_comic_id ON run_items(comic_id);
    CREATE INDEX IF NOT EXISTS idx_history_read_at ON reading_history(read_at DESC);
    CREATE INDEX IF NOT EXISTS idx_bookmarks_comic ON bookmarks(comic_id);
    CREATE INDEX IF NOT EXISTS idx_comics_pub_series_issue ON comics(publisher, series, issue_number) WHERE deleted_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_comics_writer ON comics(writer) WHERE deleted_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_comics_penciller ON comics(penciller) WHERE deleted_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_comics_year ON comics(year) WHERE deleted_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_metadata_conflicts_status ON metadata_conflicts(status) WHERE status = 'pending';
    CREATE INDEX IF NOT EXISTS idx_metadata_conflicts_comic ON metadata_conflicts(comic_id);
    CREATE INDEX IF NOT EXISTS idx_bookmarks_favorite ON bookmarks(is_favorite) WHERE is_favorite = 1;
    CREATE INDEX IF NOT EXISTS idx_rp_last_read ON reading_progress(last_read DESC);
    CREATE INDEX IF NOT EXISTS idx_rp_comic_id ON reading_progress(comic_id);
    """
}
