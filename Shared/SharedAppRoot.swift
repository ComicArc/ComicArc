import SwiftUI
import CoreSpotlight

/// The `WindowGroup` content shared identically by the iPad and visionOS app entry points --
/// they present the exact same `iPadRootView` (visionOS reuses it wholesale, no UI of its own),
/// with the same onboarding gate, environment injection, scenePhase handling, and Spotlight
/// activity handling. Mac's entry point stays separate on purpose: a different root view
/// (`ContentView`), a substantially larger command set, and an `AppDelegate`/Sparkle updater with
/// no iPad/visionOS equivalent -- not worth forcing into one shared shape.
struct SharedAppRootContent: View {
    @ObservedObject var vm: LibraryViewModel
    let fileService: any FileServiceProtocol
    let windowService: any WindowServiceProtocol

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboardingCompletedForBuild") private var completedBuild: String = ""
    private var needsOnboarding: Bool { OnboardingGate.isNeeded(completedBuild: completedBuild) }

    var body: some View {
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
}

/// `includeRenameFiles`: iPad's Library menu has a "Rename Files to Match Library…" item that
/// visionOS's doesn't -- the one real content difference between the two, preserved as a
/// parameter rather than silently dropped or force-added to both.
struct LibraryMenuCommands: Commands {
    let vm: LibraryViewModel
    var includeRenameFiles: Bool = false

    var body: some Commands {
        CommandMenu("Library") {
            Button("Scan Library") { vm.scan() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(vm.libraryPaths.isEmpty)
            if includeRenameFiles {
                Divider()
                Button("Rename Files to Match Library…") {
                    NotificationCenter.default.post(name: .triggerRenameFiles, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}

struct NavigateMenuCommands: Commands {
    let vm: LibraryViewModel

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Library")          { vm.select(.library) }         .keyboardShortcut("1", modifiers: .command)
            Button("Continue Reading") { vm.select(.continueReading) } .keyboardShortcut("2", modifiers: .command)
            Button("Favorites")        { vm.select(.favorites) }       .keyboardShortcut("3", modifiers: .command)
            Button("Reading List")     { vm.select(.readingList) }     .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Reading Paths")    { vm.select(.runs) }            .keyboardShortcut("5", modifiers: .command)
            Button("Diary")            { vm.select(.diary) }           .keyboardShortcut("6", modifiers: .command)
            Button("Statistics")       { vm.select(.stats) }           .keyboardShortcut("7", modifiers: .command)
            Button("History")          { vm.select(.history) }         .keyboardShortcut("8", modifiers: .command)
            Button("Tier Lists")       { vm.select(.tierLists) }       .keyboardShortcut("9", modifiers: .command)
            Button("Highlights")       { vm.select(.favoriteMoments) } .keyboardShortcut("0", modifiers: [.command, .shift])
            Divider()
            Button("Go Back") { vm.navigateBack() }.keyboardShortcut("[", modifiers: .command)
        }
    }
}
