import AppIntents

// A first, deliberately small App Intents surface -- previously the app had none, so it was
// invisible to Shortcuts, Siri, and Spotlight's "Suggested Shortcuts". Only intents that are
// safe to run unattended (no destructive actions, no ambiguous parameters) are exposed here.

struct ScanLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan Comic Library"
    static var description = IntentDescription("Scans your ComicArc library folders for new, changed, or removed comics.")

    @MainActor
    func perform() async throws -> some IntentResult {
        LibraryViewModel.shared.scan()
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

struct ComicArcShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanLibraryIntent(),
            phrases: ["Scan my comic library in \(.applicationName)"],
            shortTitle: "Scan Library",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: ShowContinueReadingIntent(),
            phrases: ["Continue reading in \(.applicationName)"],
            shortTitle: "Continue Reading",
            systemImageName: "book.fill"
        )
    }
}
