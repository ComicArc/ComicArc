import SwiftUI

@main
struct ComicArcIPadApp: App {
    @StateObject private var vm = LibraryViewModel.shared

    private let fileService   = makePlatformFileService()
    private let windowService = makePlatformWindowService()

    var body: some Scene {
        WindowGroup {
            iPadRootView()
                .environmentObject(vm)
                .environment(\.fileService, fileService)
                .environment(\.windowService, windowService)
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
                Button("Creators")         { vm.select(.creators) }        .keyboardShortcut("8", modifiers: .command)
                Divider()
                Button("Go Back") { vm.navigateBack() }.keyboardShortcut("[", modifiers: .command)
            }
        }
    }
}
