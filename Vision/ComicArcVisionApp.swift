import SwiftUI
import CoreSpotlight

/// visionOS entry point -- a plain windowed app (no immersive space), reusing the exact same
/// shared Database/Models/Services/Scanner/Views/ViewModels code as ComicArcPad, plus iPadRootView
/// itself directly. visionOS's windowed-app SwiftUI surface is close enough to iPadOS's that this
/// needed no new UI of its own for a first version -- the same 3-column NavigationSplitView reader
/// works as a window in the Shared Space. Deliberately not attempting an immersive space or a
/// spatial-specific redesign here; that's a real, separate design exercise, not a mechanical port.
@main
struct ComicArcVisionApp: App {
    @StateObject private var vm = LibraryViewModel.shared
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("onboardingCompletedForBuild") private var completedBuild: String = ""

    private let fileService   = makePlatformFileService()
    private let windowService = makePlatformWindowService()

    private var needsOnboarding: Bool { OnboardingGate.isNeeded(completedBuild: completedBuild) }

    var body: some Scene {
        WindowGroup {
            Group {
                if needsOnboarding {
                    OnboardingView {
                        completedBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
                        vm.reload()
                    }
                } else {
                    iPadRootView()
                }
            }
                .environmentObject(vm)
                .environment(\.fileService, fileService)
                .environment(\.windowService, windowService)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, !vm.libraryPaths.isEmpty { vm.scan() }
                    if phase == .background { DatabaseManager.shared.checkpoint() }
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    vm.openComicFromSpotlight(activity)
                }
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Library") {
                Button("Scan Library") { vm.scan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(vm.libraryPaths.isEmpty)
            }

            CommandMenu("Navigate") {
                Button("Library")          { vm.select(.library) }         .keyboardShortcut("1", modifiers: .command)
                Button("Continue Reading") { vm.select(.continueReading) } .keyboardShortcut("2", modifiers: .command)
                Button("Favorites")        { vm.select(.favorites) }       .keyboardShortcut("3", modifiers: .command)
                Button("Reading List")     { vm.select(.readingList) }     .keyboardShortcut("4", modifiers: .command)
                Divider()
                Button("Reading Paths")   { vm.select(.runs) }            .keyboardShortcut("5", modifiers: .command)
                Button("Diary")            { vm.select(.diary) }           .keyboardShortcut("6", modifiers: .command)
                Button("Statistics")       { vm.select(.stats) }           .keyboardShortcut("7", modifiers: .command)
                Button("History")          { vm.select(.history) }         .keyboardShortcut("8", modifiers: .command)
                Divider()
                Button("Go Back") { vm.navigateBack() }.keyboardShortcut("[", modifiers: .command)
            }
        }
    }
}
