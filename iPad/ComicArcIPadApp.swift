import SwiftUI
import CoreSpotlight

@main
struct ComicArcIPadApp: App {
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
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Library") {
                Button("Scan Library") { vm.scan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(vm.libraryPaths.isEmpty)
                Divider()
                Button("Rename Files to Match Library…") {
                    NotificationCenter.default.post(name: .triggerRenameFiles, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
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
                Button("Tier Lists")       { vm.select(.tierLists) }       .keyboardShortcut("9", modifiers: .command)
                Button("Favorite Moments") { vm.select(.favoriteMoments) } .keyboardShortcut("0", modifiers: [.command, .shift])
                Divider()
                Button("Go Back") { vm.navigateBack() }.keyboardShortcut("[", modifiers: .command)
            }
        }
    }
}
