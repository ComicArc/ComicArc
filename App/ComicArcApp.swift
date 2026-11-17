import SwiftUI
import CoreSpotlight

@main
struct ComicArcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("ComicArc", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(Theme.scheme)
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = SpotlightIndex.comicID(from: activity) { model.open(comicID: id) }
                }
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 620, height: 560)
                .preferredColorScheme(Theme.scheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServicesProvider()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No AppKit window restoration: the window frame is saved by `WindowConfigurator`, and
        // restoring a previous build's toolbar state has crashed AppKit.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        // One copy at a time; ignore a previous copy that is still shutting down.
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0 != .current && !$0.isTerminated }) {
            other.activate()
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        // Mouse side buttons go back and forward.
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
            Task { @MainActor in
                let model = AppModel.shared
                if event.buttonNumber == 3 { model.goBack() } else { model.goForward() }
            }
            return nil
        }
        Task { @MainActor in AppModel.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        RarExtractionCache.shared.clear()
        Database.shared.checkpoint()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.importFiles(urls) }
    }
}

/// "Add to ComicArc" in Finder's Services menu.
final class ServicesProvider: NSObject {
    @objc func importFilesService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else {
            error.pointee = "No files selected"
            return
        }
        Task { @MainActor in AppModel.shared.importFiles(urls) }
    }
}

/// Restores the window frame under a stable key (SwiftUI's own key changes between builds) and
/// opens the first window filling the screen.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            window.collectionBehavior.insert(.fullScreenPrimary)
            if let saved = UserDefaults.standard.string(forKey: Prefs.windowFrame) {
                window.setFrame(from: saved)
            } else if let screen = window.screen ?? NSScreen.main {
                window.setFrame(screen.visibleFrame, display: true)
            }
            context.coordinator.observe(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var tokens: [NSObjectProtocol] = []
        func observe(_ window: NSWindow) {
            let save: (Notification) -> Void = { [weak window] _ in
                guard let window, !window.styleMask.contains(.fullScreen) else { return }
                UserDefaults.standard.set(window.frameDescriptor, forKey: Prefs.windowFrame)
            }
            let nc = NotificationCenter.default
            tokens = [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.willCloseNotification]
                .map { nc.addObserver(forName: $0, object: window, queue: .main, using: save) }
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Comics…") { ImportPanel.run(model) }.keyboardShortcut("o")
        }
        CommandMenu("Library") {
            Button("Scan for New Comics") { model.rescan() }.keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.folders.isEmpty || model.scan.running)
            Button("Resync Library") { model.resync() }.keyboardShortcut("r", modifiers: [.command, .shift, .option])
                .disabled(model.folders.isEmpty || model.scan.running)
            Divider()
            Button(model.selecting ? "Done Selecting" : "Select Comics") {
                if model.selecting { model.endSelection() } else { model.selecting = true }
            }
            .keyboardShortcut("e")
            .disabled(model.reader != nil)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(navigation.enumerated()), id: \.offset) { index, item in
                Button(item.title) { model.reader = nil; model.sidebar = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Button("Back") { model.goBack() }.keyboardShortcut("[").disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }.keyboardShortcut("]").disabled(!model.canGoForward)
            Button("Quick Open…") { model.quickOpen = true }.keyboardShortcut("k").disabled(model.reader != nil)
        }
        CommandGroup(replacing: .help) {
            Button("Welcome Tour") { model.reader = nil; model.showOnboarding = true }
            Button("Reader Keyboard Shortcuts") { NotificationCenter.default.post(name: .showReaderHelp, object: nil) }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }

    private var navigation: [SidebarItem] { [.home, .continueReading, .favorites, .paths, .highlights, .stats] }
}
