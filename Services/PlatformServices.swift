import Foundation
import UniformTypeIdentifiers
import SwiftUI

// Both are UI services, so they're main-actor isolated.
@MainActor
protocol FileServiceProtocol {
    func pickFiles(
        allowsMultiple: Bool,
        message: String,
        prompt: String,
        contentTypes: [UTType],
        completion: @escaping ([URL]) -> Void
    )
    func pickFolder(completion: @escaping (URL?) -> Void)
    func pickSaveDestination(filename: String, completion: @escaping (URL?) -> Void)
    func revealInFinder(_ url: URL)

    /// Moves a file to the system Trash and returns its new location (for undo), or nil if that
    /// failed.
    func moveToTrash(_ url: URL) -> URL?

    func shareFile(_ url: URL)
}

@MainActor
protocol WindowServiceProtocol {
    func toggleFullScreen()
    func enterImmersiveMode()
    func exitImmersiveMode()
    func showCursor()
    func configureMainWindow()

    /// Opens the print panel for a page image. No-op on iPad.
    func printImage(_ image: PlatformImage)
}

struct NoOpFileService: FileServiceProtocol {
    // `nonisolated` so these can be used as EnvironmentKey default values.
    nonisolated init() {}
    func pickFiles(allowsMultiple: Bool, message: String, prompt: String, contentTypes: [UTType],
                   completion: @escaping ([URL]) -> Void) { completion([]) }
    func pickFolder(completion: @escaping (URL?) -> Void) { completion(nil) }
    func pickSaveDestination(filename: String, completion: @escaping (URL?) -> Void) { completion(nil) }
    func revealInFinder(_ url: URL) {}
    func moveToTrash(_ url: URL) -> URL? { nil }
    func shareFile(_ url: URL) {}
}

struct NoOpWindowService: WindowServiceProtocol {
    nonisolated init() {}
    func toggleFullScreen() {}
    func enterImmersiveMode() {}
    func exitImmersiveMode() {}
    func showCursor() {}
    func configureMainWindow() {}
    func printImage(_ image: PlatformImage) {}
}

@MainActor
func makePlatformFileService() -> any FileServiceProtocol {
    #if os(macOS)
    MacFileService()
    #elseif os(iOS) || os(visionOS)
    IOSFileService()
    #else
    NoOpFileService()
    #endif
}

@MainActor
func makePlatformWindowService() -> any WindowServiceProtocol {
    #if os(macOS)
    MacWindowService()
    #else
    NoOpWindowService()
    #endif
}

private struct FileServiceKey: EnvironmentKey {
    static let defaultValue: any FileServiceProtocol = NoOpFileService()
}

private struct WindowServiceKey: EnvironmentKey {
    static let defaultValue: any WindowServiceProtocol = NoOpWindowService()
}

/// Namespace shared by covers and the reader's hero layer for the open/close cover animation. Nil
/// where there's no reader.
private struct ReaderNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var fileService: any FileServiceProtocol {
        get { self[FileServiceKey.self] }
        set { self[FileServiceKey.self] = newValue }
    }

    var windowService: any WindowServiceProtocol {
        get { self[WindowServiceKey.self] }
        set { self[WindowServiceKey.self] = newValue }
    }

    var readerNamespace: Namespace.ID? {
        get { self[ReaderNamespaceKey.self] }
        set { self[ReaderNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Applies `matchedGeometryEffect` only when a namespace is present. The reader's hero layer
    /// passes `isSource: false`.
    @ViewBuilder
    func heroGeometry(id: some Hashable, in namespace: Namespace.ID?, isSource: Bool = true) -> some View {
        if let namespace {
            self.matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
        } else {
            self
        }
    }
}

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

    func showCursor() {
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    /// Runs from onAppear, possibly before the window is key, so the window is looked up directly.
    /// SwiftUI's own frame autosave key changes between builds, so the frame is saved by
    /// `MainWindowFrame` instead; with nothing saved, the window fills the screen.
    func configureMainWindow() {
        DispatchQueue.main.async {
            guard let win = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            win.titleVisibility = .hidden
            // No AppKit state restoration: restoring a previous build's toolbar state has crashed
            // in AppKit's toolbar layout.
            win.isRestorable = false
            UserDefaults.standard.removeObject(forKey: "NSToolbar Configuration main")
            MainWindowFrame.restore(win)
        }
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

/// Saves the main window's frame under a stable key.
enum MainWindowFrame {
    private static let key = "mainWindowFrame"
    private static var observers: [NSObjectProtocol] = []

    static func restore(_ win: NSWindow) {
        guard observers.isEmpty else { return }
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            win.setFrame(from: saved)
        } else if let screen = win.screen ?? NSScreen.main {
            win.setFrame(screen.visibleFrame, display: true)
        }
        let center = NotificationCenter.default
        let save: (Notification) -> Void = { note in
            guard let w = note.object as? NSWindow, w === win else { return }
            UserDefaults.standard.set(w.frameDescriptor, forKey: key)
        }
        observers = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: win, queue: .main, using: save),
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: win, queue: .main, using: save),
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: win, queue: .main, using: save),
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                if !win.styleMask.contains(.fullScreen) {
                    UserDefaults.standard.set(win.frameDescriptor, forKey: key)
                }
            },
        ]
    }

}
#endif

#if os(iOS) || os(visionOS)
import UIKit
import UniformTypeIdentifiers
import os

private let libraryFolderBookmarksKey = "libraryFolderBookmarks"
private let fileServiceLogger = Logger(subsystem: "com.comicarc", category: "fileservice")

/// Resolves each library folder's security-scoped bookmark and starts access for the app's
/// lifetime. Bookmarks that fail to resolve are dropped.
@discardableResult
func resolveLibraryFolderBookmarks() -> [URL] {
    guard let bookmarks = UserDefaults.standard.array(forKey: libraryFolderBookmarksKey) as? [Data] else { return [] }
    var resolved: [URL] = []
    var refreshed: [Data] = []
    for data in bookmarks {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { continue }
        resolved.append(url)
        if stale, let fresh = try? url.bookmarkData() {
            refreshed.append(fresh)
        } else {
            refreshed.append(data)
        }
    }
    if refreshed != bookmarks {
        UserDefaults.standard.set(refreshed, forKey: libraryFolderBookmarksKey)
    }
    return resolved
}

/// Removes one folder's bookmark (matched by resolved path), so a removed folder doesn't come back
/// on next launch.
func removeLibraryFolderBookmark(path: String) {
    guard let bookmarks = UserDefaults.standard.array(forKey: libraryFolderBookmarksKey) as? [Data] else { return }
    let remaining = bookmarks.filter { data in
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return false }
        return url.path != path
    }
    UserDefaults.standard.set(remaining, forKey: libraryFolderBookmarksKey)
}

private final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void
    init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick; self.onCancel = onCancel
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls)
        IOSFileService.retainedDelegates.removeAll { $0 === self }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onCancel()
        IOSFileService.retainedDelegates.removeAll { $0 === self }
    }
}

struct IOSFileService: FileServiceProtocol {
    fileprivate static var retainedDelegates: [DocumentPickerDelegate] = []

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
                     ?? scene?.windows.first?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    private func present(_ picker: UIDocumentPickerViewController, delegate: DocumentPickerDelegate) {
        Self.retainedDelegates.append(delegate)
        picker.delegate = delegate
        DispatchQueue.main.async { self.topViewController()?.present(picker, animated: true) }
    }

    func pickFiles(allowsMultiple: Bool, message: String, prompt: String, contentTypes: [UTType],
                   completion: @escaping ([URL]) -> Void) {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes.isEmpty ? [.item] : contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultiple
        present(picker, delegate: DocumentPickerDelegate(onPick: completion, onCancel: { completion([]) }))
    }

    /// Appends a newly picked folder's bookmark.
    func pickFolder(completion: @escaping (URL?) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        let delegate = DocumentPickerDelegate(onPick: { urls in
            guard let folder = urls.first, folder.startAccessingSecurityScopedResource() else {
                completion(nil); return
            }
            if let bookmark = try? folder.bookmarkData() {
                var existing = UserDefaults.standard.array(forKey: libraryFolderBookmarksKey) as? [Data] ?? []
                existing.append(bookmark)
                UserDefaults.standard.set(existing, forKey: libraryFolderBookmarksKey)
            }
            completion(folder)
        }, onCancel: { completion(nil) })
        present(picker, delegate: delegate)
    }

    func pickSaveDestination(filename: String, completion: @escaping (URL?) -> Void) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: tmp)
        completion(tmp)
    }

    func revealInFinder(_ url: URL) {}

    func moveToTrash(_ url: URL) -> URL? {
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return resultingURL as URL?
        } catch {
            fileServiceLogger.error("Failed to move '\(url.lastPathComponent)' to Trash: \(error.localizedDescription)")
            return nil
        }
    }

    func shareFile(_ url: URL) {
        DispatchQueue.main.async {
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let top = self.topViewController() {
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = top.view
                    popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                top.present(activity, animated: true)
            }
        }
    }
}
#endif
