#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import os

private let fileServiceLogger = Logger(subsystem: "com.comicarc", category: "fileservice")

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
            // A caller treats this as "trashing failed, leave the file alone" -- but if the DB
            // side of a delete already committed, silently returning nil here means the file
            // stays on disk with no trace of why the trash step didn't happen.
            fileServiceLogger.error("Failed to move '\(url.lastPathComponent)' to Trash: \(error.localizedDescription)")
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

    func printImage(_ image: NSImage) {
        let imageView = NSImageView(image: image)
        imageView.frame = NSRect(origin: .zero, size: image.size)
        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        let operation = NSPrintOperation(view: imageView, printInfo: printInfo)
        operation.showsPrintPanel = true
        operation.run()
    }
}
#endif
