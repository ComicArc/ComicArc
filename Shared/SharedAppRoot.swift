import SwiftUI
import CoreSpotlight

/// Entry point for the iPad and visionOS apps (visionOS reuses the iPad interface).
@main
struct ComicArcTouchApp: App {
    @StateObject private var vm = LibraryViewModel.shared
    private let fileService   = makePlatformFileService()
    private let windowService = makePlatformWindowService()

    var body: some Scene {
        WindowGroup {
            SharedAppRootContent(vm: vm, fileService: fileService, windowService: windowService)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            #if os(visionOS)
            LibraryMenuCommands(vm: vm)
            #else
            LibraryMenuCommands(vm: vm, includeRenameFiles: true)
            #endif
            NavigateMenuCommands(vm: vm)
        }
    }
}

/// The window content shared by the iPad and visionOS apps (both show `iPadRootView`). The Mac app
/// has its own root.
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

/// `includeRenameFiles`: only the iPad menu has Rename Files.
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
            Button("Reading Paths")    { vm.select(.runs) }            .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Stats")            { vm.select(.stats) }           .keyboardShortcut("5", modifiers: .command)
            Button("Highlights")       { vm.select(.favoriteMoments) } .keyboardShortcut("6", modifiers: .command)
            Divider()
            Button("Go Back") { vm.navigateBack() }.keyboardShortcut("[", modifiers: .command)
        }
    }
}
