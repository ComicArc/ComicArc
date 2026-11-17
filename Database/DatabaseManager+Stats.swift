import Foundation
import SQLite3

extension DatabaseManager {
    /// Sort orders whose field is empty for every comic in the library, so they can be hidden.
    func sortOrdersWithoutData() -> Set<SortOrder> {
        let fields: [(SortOrder, String)] = [(.writer, "writer"), (.storyArc, "story_arc"), (.year, "year")]
        return queue.sync {
            Set(fields.filter { _, column in
                scalarInt("SELECT EXISTS(SELECT 1 FROM comics WHERE deleted_at IS NULL AND \(column) IS NOT NULL AND \(column) != '')") == 0
            }.map(\.0))
        }
    }

    func loadStats() -> LibraryStats {
        queue.sync {
            let total     = scalarInt("SELECT COUNT(*) FROM comics WHERE deleted_at IS NULL")
            let pagesRead = scalarInt("SELECT COALESCE(SUM(rp.current_page),0) FROM reading_progress rp JOIN comics c ON rp.comic_id = c.id WHERE c.deleted_at IS NULL")
            let favorites = scalarInt("SELECT COUNT(*) FROM favorites f JOIN comics c ON f.comic_id = c.id WHERE c.deleted_at IS NULL")
            let inProg    = scalarInt("""
                SELECT COUNT(*) FROM comics c JOIN reading_progress rp ON c.id = rp.comic_id
                WHERE rp.current_page > 0 AND (c.page_count = 0 OR rp.current_page < c.page_count - 2) AND c.deleted_at IS NULL
            """)
            let finished  = scalarInt("""
                SELECT COUNT(*) FROM comics c JOIN reading_progress rp ON c.id = rp.comic_id
                WHERE c.page_count > 1 AND rp.current_page >= c.page_count - 2 AND c.deleted_at IS NULL
            """)
            let runsCount = scalarInt("SELECT COUNT(*) FROM runs")

            let streak = computeStreak(dates: streakDates())

            let activityMap = readingActivityMap(days: 365)

            let pubRows = rows("""
                SELECT publisher, COUNT(*) FROM comics WHERE deleted_at IS NULL
                GROUP BY publisher ORDER BY COUNT(*) DESC
            """) { PublisherStat(publisher: colText($0, 0) ?? "", count: colInt($0, 1)) }

            let seriesRows = rows("""
                SELECT series, publisher, COUNT(*) FROM comics WHERE deleted_at IS NULL
                GROUP BY publisher, series ORDER BY COUNT(*) DESC LIMIT 5
            """) { SeriesStat(series: colText($0, 0) ?? "", publisher: colText($0, 1) ?? "", count: colInt($0, 2)) }

            let recent = rows("""
                \(comicSelect)
                WHERE c.deleted_at IS NULL AND rp.comic_id IS NOT NULL
                ORDER BY rp.last_read DESC LIMIT 8
            """, map: comicRow)

            let growth = monthlyCollectionGrowth(months: 6)

            return LibraryStats(totalComics: total, pagesRead: pagesRead, favorites: favorites,
                                inProgress: inProg, finished: finished, unread: max(0, total - inProg - finished),
                                runsCount: runsCount, readingStreak: streak, activityMap: activityMap,
                                publisherBreakdown: pubRows, topSeries: seriesRows, recentlyRead: recent,
                                collectionGrowth: growth)
        }
    }

    // Call from inside queue.sync (it doesn't take the queue itself). Days are bucketed in local
    // time, since last_read is stored in UTC.
    private func streakDates() -> [String] {
        rows("""
            SELECT DISTINCT date(last_read, 'localtime') FROM reading_progress ORDER BY date(last_read, 'localtime') DESC
            """) { colText($0, 0) ?? "" }
    }

    func monthlyCollectionGrowth(months: Int) -> [GrowthPoint] {
        let raw = rows("""
            SELECT strftime('%Y-%m', added_at) as ym, COUNT(*)
            FROM comics
            WHERE deleted_at IS NULL AND added_at >= date('now', '-\(months) months', 'start of month')
            GROUP BY ym ORDER BY ym
        """) { (colText($0, 0) ?? "", colInt($0, 1)) }
        let counts = Dictionary(uniqueKeysWithValues: raw)

        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM"; fmt.locale = Locale(identifier: "en_US_POSIX")
        let labelFmt = DateFormatter(); labelFmt.dateFormat = "MMM"; labelFmt.locale = Locale(identifier: "en_US_POSIX")

        var points: [GrowthPoint] = []
        for offset in stride(from: months - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .month, value: -offset, to: Date()) else { continue }
            let key = fmt.string(from: date)
            points.append(GrowthPoint(label: labelFmt.string(from: date), count: counts[key] ?? 0))
        }
        return points
    }

    // Parses a local "yyyy-MM-dd" day from the queries above, so it must use the local time zone.
    static let yyyyMMddFormatter: DateFormatter = {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    // Local-time days, matching the heatmap's local calendar keys.
    func readingActivityMap(days: Int) -> [String: Int] {
        var map: [String: Int] = [:]
        let rows = self.rows("""
            SELECT date(last_read, 'localtime') as d, COUNT(*) FROM reading_progress
            WHERE last_read >= date('now', '-\(days) days')
            GROUP BY d
        """) { (colText($0, 0) ?? "", colInt($0, 1)) }
        for (d, c) in rows { map[d] = c }
        return map
    }

    func computeStreak(dates: [String]) -> Int {
        guard !dates.isEmpty else { return 0 }
        let fmt = Self.yyyyMMddFormatter
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return 0 }
        var streak = 0; var expected: Date?
        for str in dates {
            guard let d = fmt.date(from: str) else { continue }
            let day = cal.startOfDay(for: d)
            if expected == nil {
                guard day == today || day == yesterday else { break }
                streak = 1; expected = cal.date(byAdding: .day, value: -1, to: day)
            } else if day == expected {
                streak += 1; expected = cal.date(byAdding: .day, value: -1, to: day)
            } else { break }
        }
        return streak
    }

    func readingHistory(limit: Int = 100) -> [HistoryEntry] {
        queue.sync {
            let sql = """
                SELECT h.id, h.comic_id, c.title, c.publisher, c.series,
                       h.page_start, h.page_end, h.read_at
                FROM reading_history h
                JOIN comics c ON c.id = h.comic_id
                ORDER BY h.read_at DESC
                LIMIT \(limit)
            """
            return rows(sql) { s in
                HistoryEntry(
                    id: colInt64(s, 0), comicId: colInt64(s, 1),
                    title: colText(s, 2) ?? "", publisher: colText(s, 3) ?? "",
                    series: colText(s, 4) ?? "",
                    pageStart: colInt(s, 5), pageEnd: colInt(s, 6),
                    readAt: colText(s, 7) ?? ""
                )
            }
        }
    }

    /// Comics finished this calendar year (local time), for the reading-goal ring.
    func issuesReadThisYear() -> Int {
        queue.sync {
            let year = String(Calendar.current.component(.year, from: Date()))
            return scalarInt("""
                SELECT COUNT(*) FROM reading_progress rp JOIN comics c ON c.id = rp.comic_id
                WHERE c.deleted_at IS NULL AND strftime('%Y', rp.finished_at, 'localtime') = ?
                """, args: [year])
        }
    }

    func readingGoal(year: Int) -> Int {
        queue.sync {
            let v = scalarInt("SELECT goal_count FROM reading_goals WHERE year=?", args: [year])
            return v == 0 ? 52 : v
        }
    }

    func setReadingGoal(year: Int, count: Int) {
        queue.async {
            _ = self.run("INSERT OR REPLACE INTO reading_goals (year, goal_count) VALUES (?,?)", args: [year, count])
        }
    }

    /// Years with at least one reading session, most recent first.
    func availableReadingYears() -> [Int] {
        queue.sync {
            rows("SELECT DISTINCT strftime('%Y', read_at) FROM reading_history ORDER BY 1 DESC") { colText($0, 0) }
                .compactMap { Int($0 ?? "") }
        }
    }

    struct YearInReviewStats {
        let year: Int
        let issuesRead: Int
        let pagesRead: Int
        let topSeries: (name: String, count: Int)?
        let topPublisher: (name: String, count: Int)?
        let longestStreakDays: Int
        let busiestMonthLabel: String?
    }

    func yearInReview(year: Int) -> YearInReviewStats {
        queue.sync {
            let yearStr = String(year)

            let issuesRead = scalarInt(
                "SELECT COUNT(DISTINCT comic_id) FROM reading_history WHERE strftime('%Y', read_at) = ?", args: [yearStr])
            let pagesRead = scalarInt(
                "SELECT COALESCE(SUM(page_end - page_start + 1), 0) FROM reading_history WHERE strftime('%Y', read_at) = ?",
                args: [yearStr])

            let topSeries = rows("""
                SELECT c.series, COUNT(DISTINCT h.comic_id) as n
                FROM reading_history h JOIN comics c ON c.id = h.comic_id
                WHERE strftime('%Y', h.read_at) = ?
                GROUP BY c.publisher, c.series ORDER BY n DESC LIMIT 1
                """, args: [yearStr]) { (name: colText($0, 0) ?? "", count: colInt($0, 1)) }.first

            let topPublisher = rows("""
                SELECT c.publisher, COUNT(DISTINCT h.comic_id) as n
                FROM reading_history h JOIN comics c ON c.id = h.comic_id
                WHERE strftime('%Y', h.read_at) = ?
                GROUP BY c.publisher ORDER BY n DESC LIMIT 1
                """, args: [yearStr]) { (name: colText($0, 0) ?? "", count: colInt($0, 1)) }.first

            let distinctDays: [String] = rows(
                "SELECT DISTINCT date(read_at, 'localtime') as d FROM reading_history WHERE strftime('%Y', read_at) = ?",
                args: [yearStr]) { colText($0, 0) ?? "" }
            let longestStreakDays = longestStreak(dates: distinctDays)

            let busiestMonthNum = rows("""
                SELECT strftime('%m', read_at) as m, COUNT(DISTINCT comic_id) as n
                FROM reading_history WHERE strftime('%Y', read_at) = ?
                GROUP BY m ORDER BY n DESC LIMIT 1
                """, args: [yearStr]) { colText($0, 0) ?? "" }.first
            let busiestMonthLabel = busiestMonthNum.flatMap { $0.isEmpty ? nil : Self.monthName(from: $0) }

            return YearInReviewStats(
                year: year, issuesRead: issuesRead, pagesRead: pagesRead,
                topSeries: topSeries, topPublisher: topPublisher,
                longestStreakDays: longestStreakDays,
                busiestMonthLabel: busiestMonthLabel
            )
        }
    }

    static func monthName(from monthNumber: String) -> String? {
        guard let n = Int(monthNumber), (1...12).contains(n) else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.monthSymbols[n - 1]
    }

    /// Longest run of consecutive reading days in `dates` (unlike `computeStreak`, not anchored to
    /// today).
    func longestStreak(dates: [String]) -> Int {
        let cal = Calendar.current
        let days = dates.compactMap { Self.yyyyMMddFormatter.date(from: $0) }
            .map { cal.startOfDay(for: $0) }
            .sorted()
        guard !days.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for i in 1..<days.count {
            if let expected = cal.date(byAdding: .day, value: 1, to: days[i - 1]), expected == days[i] {
                current += 1
                longest = max(longest, current)
            } else if days[i] != days[i - 1] {
                current = 1
            }
        }
        return longest
    }

}
