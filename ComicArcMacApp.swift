import SwiftUI

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Backs both Dock-icon drag-and-drop and Finder's "Import to ComicArc" service — kept
    // alive for the app's lifetime since NSApp.servicesProvider holds only a weak-ish
    // reference in practice (the services dispatch mechanism doesn't retain it for you).
    private let servicesProvider = ComicArcServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = servicesProvider
    }

    // Closing the window means the app is fully quit — no lingering in the background with
    // the watcher, scanner, and DB connection still alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Quitting should mean quitting: stop the file watcher, cancel any in-flight scan
    // (and kill the `unar` subprocess it may be blocked on) and cleanly close the
    // database before the process actually exits, instead of relying on the OS to
    // reclaim everything abruptly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LibraryViewModel.shared.shutdown()
        return .terminateNow
    }

    // Covers three routes at once, all funneled through the same AppKit hook: double-clicking
    // a .cbz/.cbr/.pdf in Finder ("Open With ComicArc"), dragging one onto the Dock icon while
    // the app is already running or launching it fresh, and `open -a ComicArc file.cbz` from
    // the command line. Declaring CFBundleDocumentTypes in Info.plist is what makes macOS
    // route these events here at all — without it this method is simply never called.
    func application(_ application: NSApplication, open urls: [URL]) {
        let comics = urls.filter { ["cbz", "cbr", "pdf"].contains($0.pathExtension.lowercased()) }
        guard !comics.isEmpty else { return }
        LibraryViewModel.shared.importFiles(comics)
    }
}

// Handler for the "Import to ComicArc" Finder Services menu item (Info.plist NSServices).
// Must be an NSObject subclass with an @objc method matching the NSMessage key exactly,
// suffixed with the standard Services selector shape (pboard:userData:error:) — AppKit
// invokes this by string-based selector lookup, not a Swift protocol, so the signature has
// to match exactly or the service silently does nothing when clicked.
final class ComicArcServicesProvider: NSObject {
    @objc func importFilesService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            error.pointee = "No comic files found on the pasteboard"
            return
        }
        let comics = urls.filter { ["cbz", "cbr", "pdf"].contains($0.pathExtension.lowercased()) }
        guard !comics.isEmpty else {
            error.pointee = "No .cbz, .cbr, or .pdf files selected"
            return
        }
        DispatchQueue.main.async {
            LibraryViewModel.shared.importFiles(comics)
        }
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

            // Settings is now an in-app page (ContentView's detailContent .settings case)
            // rather than a separate floating Settings{} scene, so ⌘, and the app-menu
            // "Settings…" item are redirected to select it instead of opening a new window —
            // replacing the default .appSettings command group is what keeps macOS from
            // auto-generating its own "Settings…" item pointing at a scene that no longer exists.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { vm.select(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }

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
    }
}
