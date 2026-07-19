import SwiftUI

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Closing the window should mean the app is actually closed — no lingering in the
    // background/Dock with the watcher, scanner, and DB connection all still alive. This
    // used to be a hidden, defaulted-off Settings toggle, so closing the window did nothing
    // for most people; now it always fully quits, running the same cleanup as Cmd+Q below.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Quitting should mean quitting: stop the file watcher, cancel any in-flight scan
    // (and kill the `unar` subprocess it may be blocked on) and cleanly close the
    // database before the process actually exits, instead of relying on the OS to
    // reclaim everything abruptly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LibraryViewModel.shared.shutdown()
        return .terminateNow
    }
}
#endif

@main
struct ComicArcApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @StateObject private var vm = LibraryViewModel.shared

    @AppStorage("onboardingCompletedForBuild") private var completedBuild: String = ""

    private let fileService   = makePlatformFileService()
    private let windowService = makePlatformWindowService()

    private var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    private var needsOnboarding: Bool { completedBuild != currentBuild }

    var body: some Scene {
        WindowGroup {
            Group {
                if needsOnboarding {
                    OnboardingView {
                        completedBuild = currentBuild
                        vm.reload()
                    }
                } else {
                    #if os(macOS)
                    ContentView().environmentObject(vm)
                    #else
                    iPadRootView().environmentObject(vm)
                    #endif
                }
            }
            #if os(macOS)
            .frame(minWidth: 960, minHeight: 640)
            #endif
            .environment(\.fileService, fileService)
            .environment(\.windowService, windowService)
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .printItem) {}

            CommandMenu("Library") {
                Button("Scan Library") { vm.scan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(vm.libraryPath.isEmpty || vm.isScanning || vm.isResyncing)
                Button("Resync Library") { vm.resyncLibrary() }
                    .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                    .disabled(vm.libraryPath.isEmpty || vm.isResyncing || vm.isScanning)
                    .help("Rescans and re-derives metadata for every comic — use if reading order or metadata looks wrong")
                Button("Import Files…") {
                    NotificationCenter.default.post(name: .triggerImport, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Mark All as Read") { vm.markAllRead() }
                    .disabled(vm.comics.isEmpty)
            }

            CommandMenu("Navigate") {
                Button("Library")          { vm.select(.library) }          .keyboardShortcut("1", modifiers: .command)
                Button("Continue Reading") { vm.select(.continueReading) }  .keyboardShortcut("2", modifiers: .command)
                Button("Favorites")        { vm.select(.favorites) }        .keyboardShortcut("3", modifiers: .command)
                Button("Reading List")     { vm.select(.readingList) }      .keyboardShortcut("4", modifiers: .command)
                Divider()
                Button("Reading Orders") { vm.select(.runs) }    .keyboardShortcut("5", modifiers: .command)
                Button("Statistics")     { vm.select(.stats) }   .keyboardShortcut("6", modifiers: .command)
                Button("History")        { vm.select(.history) } .keyboardShortcut("7", modifiers: .command)
                Button("Creators")       { vm.select(.creators) }.keyboardShortcut("8", modifiers: .command)
                Divider()
                Button("Go Back") { vm.navigateBack() }.keyboardShortcut("[", modifiers: .command)
            }

            CommandMenu("View") {
                Button("Compact Grid") { UserDefaults.standard.set("compact", forKey: "gridDensity") }.keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Regular Grid") { UserDefaults.standard.set("regular", forKey: "gridDensity") }.keyboardShortcut("2", modifiers: [.command, .shift])
                Button("Large Grid")   { UserDefaults.standard.set("large",   forKey: "gridDensity") }.keyboardShortcut("3", modifiers: [.command, .shift])
                Divider()
                Button(vm.bulkMode ? "Exit Selection Mode" : "Select Multiple") { vm.toggleBulkMode() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Select All") { vm.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(!vm.bulkMode)
                Divider()
                Button("Delete Selected") { vm.bulkDelete() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!vm.bulkMode || vm.selectedComicIds.isEmpty)
            }

            CommandGroup(replacing: .help) {
                Button("Show Tutorial") { NotificationCenter.default.post(name: .showTutorial, object: nil) }
                Button("Keyboard Shortcuts…") { NotificationCenter.default.post(name: .showReaderShortcuts, object: nil) }
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView().environmentObject(vm)
        }
        #endif
    }
}
