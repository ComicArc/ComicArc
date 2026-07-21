import SwiftUI

@main
struct ComicArcIPadApp: App {
    @StateObject private var vm = LibraryViewModel.shared
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("onboardingCompletedForBuild") private var completedBuild: String = ""

    private let fileService   = makePlatformFileService()
    private let windowService = makePlatformWindowService()

    private var needsOnboarding: Bool {
        completedBuild.isEmpty && UserDefaults.standard.string(forKey: "libraryPath").flatMap { $0.isEmpty ? nil : $0 } == nil
    }

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

                    if phase == .active, !vm.libraryPath.isEmpty { vm.scan() }

                    if phase == .background { DatabaseManager.shared.checkpoint() }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Library") {
                Button("Scan Library") { vm.scan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(vm.libraryPath.isEmpty)
            }

            CommandMenu("Navigate") {
                Button("Library")          { vm.select(.library) }         .keyboardShortcut("1", modifiers: .command)
                Button("Continue Reading") { vm.select(.continueReading) } .keyboardShortcut("2", modifiers: .command)
                Button("Favorites")        { vm.select(.favorites) }       .keyboardShortcut("3", modifiers: .command)
                Button("Reading List")     { vm.select(.readingList) }     .keyboardShortcut("4", modifiers: .command)
                Divider()
                Button("Reading Orders")   { vm.select(.runs) }            .keyboardShortcut("5", modifiers: .command)
                Button("Statistics")       { vm.select(.stats) }           .keyboardShortcut("6", modifiers: .command)
                Button("History")          { vm.select(.history) }         .keyboardShortcut("7", modifiers: .command)
                Divider()
                Button("Go Back") { vm.navigateBack() }.keyboardShortcut("[", modifiers: .command)
            }
        }
    }
}
