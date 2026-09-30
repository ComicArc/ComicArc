import SwiftUI
import CoreSpotlight
#if os(macOS)
import Sparkle
#endif

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = ComicArcServicesProvider()

    lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = servicesProvider
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LibraryViewModel.shared.shutdown()
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let comics = urls.filter { LibraryScanner.importableExtensions.contains($0.pathExtension.lowercased()) }
        guard !comics.isEmpty else { return }
        LibraryViewModel.shared.importFiles(comics)
    }
}

private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}

final class ComicArcServicesProvider: NSObject {
    @objc func importFilesService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            error.pointee = "No comic files found on the pasteboard"
            return
        }
        let comics = urls.filter { LibraryScanner.importableExtensions.contains($0.pathExtension.lowercased()) }
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
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("onboardingCompletedForBuild") private var completedBuild: String = ""
    @State private var didLaunchScan = false

    private let fileService   = makePlatformFileService()
    private let windowService = makePlatformWindowService()

    private var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    private var needsOnboarding: Bool { OnboardingGate.isNeeded(completedBuild: completedBuild) }

    var body: some Scene {
        WindowGroup {
            Group {
                if needsOnboarding {
                    OnboardingView {
                        completedBuild = currentBuild
                        vm.reload()
                    }
                } else {
                    ContentView().environmentObject(vm)
                }
            }
            .frame(minWidth: 960, minHeight: 640)
            .environment(\.fileService, fileService)
            .environment(\.windowService, windowService)
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                vm.openComicFromSpotlight(activity)
            }
            .onChange(of: scenePhase) { _, phase in
                // One scan per launch catches anything changed while the app wasn't running;
                // after that the FSEvents watcher (`FileWatcher`) picks up adds/removes live, so
                // rescanning on every window activation would just repeat work.
                guard phase == .active, !didLaunchScan, !vm.libraryPaths.isEmpty else { return }
                didLaunchScan = true
                vm.scan()
            }
        }
        #if os(macOS)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appDelegate.updaterController.updater)
            }

            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .printItem) {
                Button("Print Current Page…") {
                    NotificationCenter.default.post(name: .triggerPrint, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(vm.readerComic == nil)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { vm.select(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Library") {
                Button("Scan Library") { vm.scan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(vm.libraryPaths.isEmpty || vm.isBusy)
                Button("Resync Library") { vm.resyncLibrary() }
                    .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                    .disabled(vm.libraryPaths.isEmpty || vm.isBusy)
                    .help("Rescans and re-derives metadata for every comic — use if series, issue order, or metadata look wrong")
                Button("Import Files…") {
                    NotificationCenter.default.post(name: .triggerImport, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(vm.libraryPaths.isEmpty)
                Divider()
                Button("Rename Files to Match Library…") {
                    NotificationCenter.default.post(name: .triggerRenameFiles, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Mark All as Read") { vm.markRead(vm.comics) }
                    .disabled(vm.comics.isEmpty)
            }

            CommandMenu("Navigate") {
                Button("Library")          { vm.select(.library) }          .keyboardShortcut("1", modifiers: .command)
                Button("Continue Reading") { vm.select(.continueReading) }  .keyboardShortcut("2", modifiers: .command)
                Button("Favorites")        { vm.select(.favorites) }        .keyboardShortcut("3", modifiers: .command)
                Button("Reading Paths")    { vm.select(.runs) }             .keyboardShortcut("4", modifiers: .command)
                Divider()
                Button("Stats")            { vm.select(.stats) }            .keyboardShortcut("5", modifiers: .command)
                Button("Highlights")       { vm.select(.favoriteMoments) }  .keyboardShortcut("6", modifiers: .command)
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
                // ⇧⌘A, not ⌘A -- plain ⌘A belongs to the Edit menu's text Select All.
                Button("Select All") { vm.selectAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!vm.bulkMode)
                Divider()
                Button("Delete Selected…") { NotificationCenter.default.post(name: .triggerBulkDelete, object: nil) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!vm.bulkMode || vm.selectedComicIds.isEmpty)
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts…") { NotificationCenter.default.post(name: .showReaderShortcuts, object: nil) }
            }
        }
        #endif
    }
}
