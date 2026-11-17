import AppIntents
import AppKit

// MARK: - Shortcuts and Siri

struct ScanLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan Comic Library"
    static var description = IntentDescription("Looks for new, moved or removed comics in your library folders.")
    @MainActor func perform() async throws -> some IntentResult { await AppModel.shared.runScan(); return .result() }
}

struct ContinueReadingIntent: AppIntent {
    static var title: LocalizedStringResource = "Continue Reading"
    static var description = IntentDescription("Opens the comic you were reading most recently.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        if let c = try? await Database.shared.comics(ComicFilter(inProgressOnly: true, limit: 1)).first { AppModel.shared.open(c) }
        else { AppModel.shared.sidebar = .continueReading }
        return .result()
    }
}

struct ShowReadingListIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Reading List"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        model.sidebar = .paths
        if let id = try? await Database.shared.readingListID(create: false) { model.path = [.path(id)] }
        return .result()
    }
}

struct ComicEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Comic"
    static var defaultQuery = ComicQuery()
    var id: String
    var title: String
    var series: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(series)") }
    init(_ c: Comic) { id = String(c.id); title = c.title; series = c.series }
}

struct ComicQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ComicEntity] {
        try await Database.shared.comics(ids: identifiers.compactMap(Int64.init)).map(ComicEntity.init)
    }
    func entities(matching string: String) async throws -> [ComicEntity] {
        try await Database.shared.comics(ComicFilter(search: string, limit: 25)).map(ComicEntity.init)
    }
    func suggestedEntities() async throws -> [ComicEntity] {
        try await Database.shared.comics(ComicFilter(inProgressOnly: true, limit: 10)).map(ComicEntity.init)
    }
}

struct OpenComicIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Comic"
    static var openAppWhenRun = true
    @Parameter(title: "Comic") var comic: ComicEntity
    @MainActor func perform() async throws -> some IntentResult {
        if let id = Int64(comic.id) { AppModel.shared.open(comicID: id) }
        return .result()
    }
}

struct MarkComicReadIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark Comic as Read"
    @Parameter(title: "Comic") var comic: ComicEntity
    @MainActor func perform() async throws -> some IntentResult {
        if let id = Int64(comic.id), let c = try? await Database.shared.comic(id: id) { AppModel.shared.markRead([c]) }
        return .result()
    }
}

struct ReadingSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Reading Progress Summary"
    static var description = IntentDescription("Tells you how much you've read and your current streak.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let s = try await Database.shared.stats()
        return .result(dialog: "You've read \(s.finished) issues and \(s.pagesRead) pages. \(s.finishedThisYear) this year, on a \(s.currentStreak)-day streak.")
    }
}

struct ComicArcShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueReadingIntent(), phrases: ["Continue reading in \(.applicationName)"],
                    shortTitle: "Continue Reading", systemImageName: "book.fill")
        AppShortcut(intent: OpenComicIntent(), phrases: ["Open \(\.$comic) in \(.applicationName)"],
                    shortTitle: "Open Comic", systemImageName: "book")
        AppShortcut(intent: ScanLibraryIntent(), phrases: ["Scan my comics in \(.applicationName)"],
                    shortTitle: "Scan Library", systemImageName: "arrow.clockwise")
        AppShortcut(intent: ShowReadingListIntent(), phrases: ["Show my reading list in \(.applicationName)"],
                    shortTitle: "Reading List", systemImageName: "bookmark.fill")
        AppShortcut(intent: MarkComicReadIntent(), phrases: ["Mark \(\.$comic) as read in \(.applicationName)"],
                    shortTitle: "Mark as Read", systemImageName: "checkmark.circle")
        AppShortcut(intent: ReadingSummaryIntent(), phrases: ["How's my reading going in \(.applicationName)"],
                    shortTitle: "Reading Summary", systemImageName: "flame.fill")
    }
}

// MARK: - AppleScript (ComicArc.sdef; class names must match exactly)

@objc(ScanLibraryScriptCommand)
final class ScanLibraryScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in AppModel.shared.rescan() }
        return nil
    }
}

@objc(ResyncLibraryScriptCommand)
final class ResyncLibraryScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in AppModel.shared.resync() }
        return nil
    }
}

@objc(ShowContinueReadingScriptCommand)
final class ShowContinueReadingScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in AppModel.shared.sidebar = .continueReading }
        return nil
    }
}
