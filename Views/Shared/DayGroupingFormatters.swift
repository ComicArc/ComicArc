import Foundation

/// Shared by DiaryView and ReadingHistoryView, which both group a list of ISO-UTC timestamps into
/// day-headers and need the same three conversions -- `loggedAt`/`readAt` are stored as
/// CURRENT_TIMESTAMP (UTC), so grouping by the raw date substring would split/merge entries on a
/// UTC midnight boundary that has nothing to do with the user's actual calendar day (e.g. a
/// US-timezone evening reading session can straddle UTC midnight and get split across two day
/// headers), hence the timezone conversion in `localDayKey`.
enum DayGroupingFormatters {
    // Explicitly `nonisolated` (this being a plain enum with no actor isolation makes that
    // implicit) since `localDayKey` is called from inside `Task.detached` background contexts in
    // both views' `load()` -- a DateFormatter is safe to use concurrently once configured.
    static let utcParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static let localDayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let localTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func localDayKey(from iso: String) -> String {
        guard let d = utcParser.date(from: iso) else { return String(iso.prefix(10)) }
        return localDayKeyFormatter.string(from: d)
    }

    static func formattedGroupDate(_ iso: String) -> String {
        guard let d = localDayKeyFormatter.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .full
        return out.string(from: d).uppercased()
    }

    static func shortTime(_ iso: String) -> String {
        guard let d = utcParser.date(from: iso) else { return "" }
        return localTimeFormatter.string(from: d)
    }
}
