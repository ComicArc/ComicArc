#if os(iOS)
import UIKit
import UniformTypeIdentifiers

private let libraryFolderBookmarksKey = "libraryFolderBookmarks"

/// Resolves every configured library folder's security-scoped bookmark, granting access to each
/// (never explicitly balanced with `stopAccessingSecurityScopedResource` -- access is opened once
/// per app-launch-or-pick and held for the process lifetime, same as the original single-folder
/// version). Any bookmark that fails to resolve is silently dropped rather than blocking the rest.
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

/// Removes one folder's bookmark from the configured array (by resolved path, not by raw bookmark
/// bytes, since those can be refreshed/rewritten independently of which folder they point to) --
/// without this, `LibraryViewModel.removeLibraryFolder` removing a path from the cached
/// `libraryPaths` list would be silently undone on the next launch, when
/// `resolveLibraryFolderBookmarks()` re-resolves every bookmark still in this array and rebuilds
/// `libraryPaths` from scratch.
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

    /// Adds a newly-picked folder to the configured library folders -- appends its bookmark to
    /// the existing array rather than overwriting it, so picking a second/third folder doesn't
    /// silently drop access to the ones already configured.
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
