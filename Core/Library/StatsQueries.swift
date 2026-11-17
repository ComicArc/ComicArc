import Foundation

struct LibraryStats: Sendable {
    var total = 0, finished = 0, inProgress = 0, favorites = 0, paths = 0, pagesRead = 0
    var currentStreak = 0, longestStreak = 0
    var finishedThisYear = 0, goal = 52
    /// Local "yyyy-MM-dd" → number of reading events that day, last 365 days.
    var activity: [String: Int] = [:]
    var publishers: [(name: String, total: Int, finished: Int)] = []
    var topSeries: [(series: String, publisher: String, finished: Int, total: Int)] = []
    var growth: [(month: String, added: Int)] = []
    var unread: Int { max(0, total - finished - inProgress) }
}

struct YearInReview: Sendable {
    let year: Int
    var finished = 0, pages = 0, daysRead = 0, longestStreak = 0
    var topSeries: (name: String, count: Int)?
    var topPublisher: (name: String, count: Int)?
    var busiestMonth: (name: String, count: Int)?
    var firstFinished: Comic?
    var lastFinished: Comic?
    var covers: [Int64] = []
}

extension Database {
    /// Days with reading activity: any progress save, reading session or finished issue.
    private static let activityDays = """
        SELECT date(last_read, 'localtime') AS d FROM reading_progress WHERE last_read IS NOT NULL
        UNION ALL SELECT date(read_at, 'localtime') FROM reading_history
        UNION ALL SELECT date(finished_at, 'localtime') FROM reading_progress WHERE finished_at IS NOT NULL
        """

    func stats(year: Int = Calendar.current.component(.year, from: Date())) async throws -> LibraryStats {
        try await read { db in
            var s = LibraryStats()
            let live = "JOIN comics c ON c.id = rp.comic_id AND c.deleted_at IS NULL"
            s.total = try db.scalarInt("SELECT COUNT(*) FROM comics WHERE deleted_at IS NULL")
            s.finished = try db.scalarInt("SELECT COUNT(*) FROM reading_progress rp \(live) WHERE rp.finished_at IS NOT NULL")
            s.inProgress = try db.scalarInt("SELECT COUNT(*) FROM reading_progress rp \(live) WHERE \(ComicSQL.inProgressCondition)")
            s.favorites = try db.scalarInt("SELECT COUNT(*) FROM favorites f JOIN comics c ON c.id = f.comic_id AND c.deleted_at IS NULL")
            s.paths = try db.scalarInt("SELECT COUNT(*) FROM runs")
            s.pagesRead = try db.scalarInt("""
                SELECT COALESCE(SUM(CASE WHEN rp.finished_at IS NOT NULL THEN c.page_count ELSE rp.current_page END), 0)
                FROM reading_progress rp \(live)
                """)
            s.finishedThisYear = try db.scalarInt("""
                SELECT COUNT(*) FROM reading_progress rp \(live)
                WHERE strftime('%Y', rp.finished_at, 'localtime') = ?
                """, [String(year)])
            s.goal = try db.first("SELECT goal_count FROM reading_goals WHERE year = ?", [year]) { $0.int(0) } ?? 52

            let days = try db.query("SELECT d, COUNT(*) FROM (\(Self.activityDays)) WHERE d >= date('now', '-365 days') GROUP BY d") {
                ($0.string(0) ?? "", $0.int(1))
            }
            s.activity = Dictionary(days, uniquingKeysWith: +)
            let allDays = try db.query("SELECT DISTINCT d FROM (\(Self.activityDays)) ORDER BY d") { $0.string(0) ?? "" }
            (s.currentStreak, s.longestStreak) = Streaks.compute(allDays)

            s.publishers = try db.query("""
                SELECT c.publisher, COUNT(*), SUM(rp.finished_at IS NOT NULL) FROM comics c
                LEFT JOIN reading_progress rp ON rp.comic_id = c.id
                WHERE c.deleted_at IS NULL GROUP BY c.publisher ORDER BY COUNT(*) DESC
                """) { ($0.string(0) ?? "Unknown", $0.int(1), $0.int(2)) }
            s.topSeries = try db.query("""
                SELECT c.series, c.publisher, SUM(rp.finished_at IS NOT NULL) AS f, COUNT(*) FROM comics c
                LEFT JOIN reading_progress rp ON rp.comic_id = c.id
                WHERE c.deleted_at IS NULL GROUP BY c.publisher, c.series HAVING f > 0
                ORDER BY f DESC LIMIT 5
                """) { ($0.string(0) ?? "", $0.string(1) ?? "", $0.int(2), $0.int(3)) }
            s.growth = try db.query("""
                SELECT strftime('%Y-%m', added_at, 'localtime') AS m, COUNT(*) FROM comics
                WHERE deleted_at IS NULL AND added_at >= date('now', '-11 months', 'start of month')
                GROUP BY m ORDER BY m
                """) { ($0.string(0) ?? "", $0.int(1)) }
            return s
        }
    }

    func setReadingGoal(_ goal: Int, year: Int) async throws {
        try await write { db in try db.run("INSERT OR REPLACE INTO reading_goals (year, goal_count) VALUES (?,?)", [year, goal]) }
    }

    func history(limit: Int = 300) async throws -> [HistoryEntry] {
        try await read { db in
            try db.query("""
                SELECT h.id, h.page_start, h.page_end, h.read_at, \(ComicSQL.columns)
                FROM reading_history h JOIN comics c ON c.id = h.comic_id \(ComicSQL.joins)
                ORDER BY h.read_at DESC LIMIT \(limit)
                """) { r in
                HistoryEntry(id: r.int64(0), comic: ComicSQL.comic(from: r, offset: 4), pageStart: r.int(1),
                             pageEnd: r.int(2), readAt: SQLDate.parse(r.string(3)) ?? .distantPast)
            }
        }
    }

    /// Years with any finished issue or reading session, newest first.
    func activeYears() async throws -> [Int] {
        try await read { db in
            try db.query("SELECT DISTINCT CAST(strftime('%Y', d) AS INTEGER) AS y FROM (\(Self.activityDays)) WHERE d IS NOT NULL ORDER BY y DESC") { $0.int(0) }
        }
    }

    func yearInReview(_ year: Int) async throws -> YearInReview {
        try await read { db in
            var y = YearInReview(year: year)
            let inYear = "strftime('%Y', rp.finished_at, 'localtime') = '\(year)'"
            let finished = try db.query("""
                \(ComicSQL.select) WHERE c.deleted_at IS NULL AND \(inYear) ORDER BY rp.finished_at
                """) { ComicSQL.comic(from: $0) }
            y.finished = finished.count
            y.pages = finished.reduce(0) { $0 + $1.pageCount }
            y.firstFinished = finished.first
            y.lastFinished = finished.last
            y.covers = Array(finished.suffix(6).map(\.id).reversed())
            if let top = Dictionary(grouping: finished, by: \.series).max(by: { $0.value.count < $1.value.count }) {
                y.topSeries = (top.key, top.value.count)
            }
            if let top = Dictionary(grouping: finished, by: \.publisher).max(by: { $0.value.count < $1.value.count }) {
                y.topPublisher = (top.key, top.value.count)
            }
            let months = Dictionary(grouping: finished) { String(($0.finishedAt ?? "").prefix(7)) }
            if let busy = months.max(by: { $0.value.count < $1.value.count }),
               let date = SQLDate.parse(busy.key + "-01 00:00:00") {
                y.busiestMonth = (date.formatted(.dateTime.month(.wide)), busy.value.count)
            }
            let days = try db.query("SELECT DISTINCT d FROM (\(Self.activityDays)) WHERE strftime('%Y', d) = ? ORDER BY d",
                                    [String(year)]) { $0.string(0) ?? "" }
            y.daysRead = days.count
            y.longestStreak = Streaks.compute(days).longest
            return y
        }
    }
}

enum Streaks {
    /// (current, longest) runs of consecutive days in ascending "yyyy-MM-dd" strings. The current
    /// streak counts if the last day is today or yesterday.
    static func compute(_ days: [String]) -> (current: Int, longest: Int) {
        let cal = Calendar.current
        let dates = days.compactMap { SQLDate.day($0) }.map { cal.startOfDay(for: $0) }
        guard !dates.isEmpty else { return (0, 0) }
        var longest = 1, run = 1
        for i in 1..<max(dates.count, 1) where dates.count > 1 {
            let gap = cal.dateComponents([.day], from: dates[i - 1], to: dates[i]).day ?? 0
            if gap == 1 { run += 1 } else if gap > 1 { run = 1 }
            longest = max(longest, run)
        }
        let today = cal.startOfDay(for: Date())
        let lastGap = cal.dateComponents([.day], from: dates.last!, to: today).day ?? 99
        return (lastGap <= 1 ? run : 0, longest)
    }
}

/// SQLite stores timestamps as UTC "yyyy-MM-dd HH:mm:ss"; local days as "yyyy-MM-dd".
enum SQLDate {
    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let localDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func parse(_ s: String?) -> Date? { s.flatMap { utc.date(from: String($0.prefix(19))) } }
    static func day(_ s: String) -> Date? { localDay.date(from: s) }
    static func dayKey(_ d: Date) -> String { localDay.string(from: d) }
}
