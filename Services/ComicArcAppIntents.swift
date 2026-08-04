import AppIntents

// A deliberately conservative App Intents surface -- only intents that are safe to run
// unattended (no destructive actions, no ambiguous parameters) are exposed here.

struct ScanLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan Comic Library"
    static var description = IntentDescription("Scans your ComicArc library folders for new, changed, or removed comics.")

    @MainActor
    func perform() async throws -> some IntentResult {
        LibraryViewModel.shared.scan()
        return .result()
    }
}

struct ResyncLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Resync Comic Library"
    static var description = IntentDescription("Fully rescans your ComicArc library, re-checking metadata and reading order for every comic, not just new files.")

    @MainActor
    func perform() async throws -> some IntentResult {
        LibraryViewModel.shared.resyncLibrary()
        return .result()
    }
}

struct ShowContinueReadingIntent: AppIntent {
    static var title: LocalizedStringResource = "Continue Reading"
    static var description = IntentDescription("Opens ComicArc to your in-progress comics.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LibraryViewModel.shared.select(.continueReading)
        return .result()
    }
}

struct ShowFavoritesIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Favorites"
    static var description = IntentDescription("Opens ComicArc to your favorite comics.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LibraryViewModel.shared.select(.favorites)
        return .result()
    }
}

struct ShowReadingListIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Reading List"
    static var description = IntentDescription("Opens ComicArc to your reading list.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LibraryViewModel.shared.select(.readingList)
        return .result()
    }
}

/// A comic, exposed to Shortcuts/Siri as a pickable, searchable entity -- backed directly by the
/// same `allComics(search:)` the in-app search field already uses, so "which comic did you mean"
/// suggestions match what a user would actually find by typing in the app itself.
struct ComicEntity: AppEntity {
    // AppEntity's ID must conform to EntityIdentifierConvertible, which Int64 doesn't -- the
    // comic's real database id is kept separately as `comicId` for internal use.
    let id: String
    let comicId: Int64
    let title: String
    let series: String

    init(comic: Comic) {
        self.comicId = comic.id
        self.id = String(comic.id)
        self.title = comic.title
        self.series = comic.series
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Comic"
    static var defaultQuery = ComicEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(series)")
    }
}

struct ComicEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ComicEntity] {
        identifiers.compactMap { idString in
            guard let id = Int64(idString) else { return nil }
            return DatabaseManager.shared.comic(id: id).map { ComicEntity(comic: $0) }
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ComicEntity] {
        DatabaseManager.shared.allComics(search: string, sortOrder: .title)
            .prefix(20)
            .map { ComicEntity(comic: $0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ComicEntity] {
        DatabaseManager.shared.inProgress(limit: 10).map { ComicEntity(comic: $0) }
    }
}

struct OpenComicIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Comic"
    static var description = IntentDescription("Opens a specific comic in ComicArc's reader.")
    static var openAppWhenRun = true

    @Parameter(title: "Comic")
    var comic: ComicEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        LibraryViewModel.shared.openReader(id: comic.comicId)
        return .result()
    }
}

struct MarkComicReadIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark Comic as Read"
    static var description = IntentDescription("Marks a specific comic as read in ComicArc.")

    @Parameter(title: "Comic")
    var comic: ComicEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        if let c = DatabaseManager.shared.comic(id: comic.comicId) {
            LibraryViewModel.shared.markRead(c)
        }
        return .result()
    }
}

/// Deliberately returns a spoken summary rather than just opening the app -- a "how am I doing"
/// question is exactly the kind of thing worth answering via Siri without a screen at all.
struct ReadingProgressSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Reading Progress Summary"
    static var description = IntentDescription("Tells you your reading streak and how many issues you've read.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let stats = DatabaseManager.shared.loadStats()
        let dialog = "You've read \(stats.finished) issue\(stats.finished == 1 ? "" : "s") and \(stats.pagesRead) pages, on a \(stats.readingStreak) day streak."
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct ComicArcShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanLibraryIntent(),
            phrases: ["Scan my comic library in \(.applicationName)"],
            shortTitle: "Scan Library",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: ResyncLibraryIntent(),
            phrases: ["Resync my comic library in \(.applicationName)"],
            shortTitle: "Resync Library",
            systemImageName: "arrow.triangle.2.circlepath.circle"
        )
        AppShortcut(
            intent: ShowContinueReadingIntent(),
            phrases: ["Continue reading in \(.applicationName)"],
            shortTitle: "Continue Reading",
            systemImageName: "book.fill"
        )
        AppShortcut(
            intent: ShowFavoritesIntent(),
            phrases: ["Show my favorites in \(.applicationName)"],
            shortTitle: "Show Favorites",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: ShowReadingListIntent(),
            phrases: ["Show my reading list in \(.applicationName)"],
            shortTitle: "Show Reading List",
            systemImageName: "bookmark.fill"
        )
        AppShortcut(
            intent: OpenComicIntent(),
            phrases: ["Open \(\.$comic) in \(.applicationName)"],
            shortTitle: "Open Comic",
            systemImageName: "book"
        )
        AppShortcut(
            intent: MarkComicReadIntent(),
            phrases: ["Mark \(\.$comic) as read in \(.applicationName)"],
            shortTitle: "Mark Comic as Read",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: ReadingProgressSummaryIntent(),
            phrases: ["How's my reading going in \(.applicationName)", "What's my reading streak in \(.applicationName)"],
            shortTitle: "Reading Progress",
            systemImageName: "flame.fill"
        )
    }
}
