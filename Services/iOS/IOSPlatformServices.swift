#if os(iOS)
import UIKit
import UniformTypeIdentifiers

private let libraryFolderBookmarkKey = "libraryFolderBookmark"

@discardableResult
func resolveLibraryFolderBookmark() -> URL? {
    guard let data = UserDefaults.standard.data(forKey: libraryFolderBookmarkKey) else { return nil }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
          url.startAccessingSecurityScopedResource() else { return nil }
    if stale, let fresh = try? url.bookmarkData() {
        UserDefaults.standard.set(fresh, forKey: libraryFolderBookmarkKey)
    }
    return url
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

    func pickFiles(allowsMultiple: Bool, message: String, prompt: String,
                   completion: @escaping ([URL]) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.allowsMultipleSelection = allowsMultiple
        present(picker, delegate: DocumentPickerDelegate(onPick: completion, onCancel: { completion([]) }))
    }

    func pickFolder(completion: @escaping (URL?) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        let delegate = DocumentPickerDelegate(onPick: { urls in
            guard let folder = urls.first, folder.startAccessingSecurityScopedResource() else {
                completion(nil); return
            }
            if let bookmark = try? folder.bookmarkData() {
                UserDefaults.standard.set(bookmark, forKey: libraryFolderBookmarkKey)
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
