#if os(macOS)
import AppKit
import UniformTypeIdentifiers

struct MacFileService: FileServiceProtocol {
    func pickFiles(
        allowsMultiple: Bool,
        message: String,
        prompt: String,
        contentTypes: [UTType],
        completion: @escaping ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = allowsMultiple
        panel.message = message
        panel.prompt = prompt
        if !contentTypes.isEmpty { panel.allowedContentTypes = contentTypes }
        if panel.runModal() == .OK { completion(panel.urls) } else { completion([]) }
    }

    func pickFolder(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { completion(panel.url) } else { completion(nil) }
    }

    func pickSaveDestination(filename: String, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        if panel.runModal() == .OK { completion(panel.url) } else { completion(nil) }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func moveToTrash(_ url: URL) -> URL? {
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return resultingURL as URL?
        } catch {
            return nil
        }
    }

    func shareFile(_ url: URL) {}
}

struct MacWindowService: WindowServiceProtocol {
    func toggleFullScreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }

    func enterImmersiveMode() {
        guard let win = NSApp.mainWindow else { return }
        win.styleMask.insert(.fullSizeContentView)
        win.titlebarAppearsTransparent = true
        win.toolbar?.isVisible = false
    }

    func exitImmersiveMode() {
        guard let win = NSApp.mainWindow else { return }
        win.toolbar?.isVisible = true
        win.titlebarAppearsTransparent = false
        win.styleMask.remove(.fullSizeContentView)
    }

    func hideCursorUntilMouseMoves() {
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func showCursor() {
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    func configureMainWindow() {
        NSApp.mainWindow?.setFrameAutosaveName("ComicArcMain")
        NSApp.mainWindow?.titleVisibility = .hidden
    }
}
#endif
