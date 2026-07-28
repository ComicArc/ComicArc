import SwiftUI
#if os(macOS)
import Sparkle
#endif

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let servicesProvider = ComicArcServicesProvider()

    lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let bundleID = Bundle.main.bundleIdentifier else { return }
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
        let comics = urls.filter { ["cbz", "cbr", "pdf"].contains($0.pathExtension.lowercased()) }
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
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appDelegate.updaterController.updater)
            }

            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .printItem) {}

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { vm.select(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Library") {
                Button("Scan Library") { vm.scan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(vm.libraryPaths.isEmpty || vm.isScanning || vm.isResyncing)
                Button("Resync Library") { vm.resyncLibrary() }
                    .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                    .disabled(vm.libraryPaths.isEmpty || vm.isResyncing || vm.isScanning)
                    .help("Rescans and re-derives metadata for every comic — use if reading order or metadata looks wrong")
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
                Button("Mark All as Read") { vm.markAllRead() }
                    .disabled(vm.comics.isEmpty)
            }

            CommandMenu("Navigate") {
                Button("Library")          { vm.select(.library) }          .keyboardShortcut("1", modifiers: .command)
                Button("Continue Reading") { vm.select(.continueReading) }  .keyboardShortcut("2", modifiers: .command)
                Button("Favorites")        { vm.select(.favorites) }        .keyboardShortcut("3", modifiers: .command)
                Button("Reading List")     { vm.select(.readingList) }      .keyboardShortcut("4", modifiers: .command)
                Divider()
                Button("Reading Paths") { vm.select(.runs) }    .keyboardShortcut("5", modifiers: .command)
                Button("Diary")          { vm.select(.diary) }   .keyboardShortcut("6", modifiers: .command)
                Button("Statistics")     { vm.select(.stats) }   .keyboardShortcut("7", modifiers: .command)
                Button("History")        { vm.select(.history) } .keyboardShortcut("8", modifiers: .command)
                Button("Tier Lists")      { vm.select(.tierLists) }      .keyboardShortcut("9", modifiers: .command)
                Button("Favorite Moments") { vm.select(.favoriteMoments) }.keyboardShortcut("0", modifiers: [.command, .shift])
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
