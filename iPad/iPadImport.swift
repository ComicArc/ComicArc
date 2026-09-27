#if os(iOS) || os(visionOS)
import SwiftUI
import UniformTypeIdentifiers

struct iPadImportButton: View {
    @State private var showPicker = false
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        Button(action: { showPicker = true }) {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Import Comics")
        .sheet(isPresented: $showPicker) {
            iPadDocumentPicker { urls in
                vm.importFiles(iPadImportStorage.copyIntoLibrary(urls, vm: vm))
            }
        }
    }
}

/// `UIDocumentPickerViewController(forOpeningContentTypes:asCopy: true)` writes into a temporary,
/// app-private staging area that Apple's own documentation only guarantees lives until the picker
/// delegate callback returns -- not permanent storage. Previously the picked URLs were handed
/// straight to `importFiles`/`addSingle`, which stored that ephemeral path verbatim as the
/// comic's `file_path`; the comic could become permanently unreadable the next time iOS reclaimed
/// that staging area (relaunch, low-disk purge), with no recovery path. This copies each picked
/// file into a real, permanent, app-owned folder in Documents (visible in the Files app, so the
/// user can find/back up their own comics) before it's ever inserted into the database.
enum iPadImportStorage {
    @MainActor
    static func copyIntoLibrary(_ urls: [URL], vm: LibraryViewModel) -> [URL] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return urls }
        let dest = docs.appendingPathComponent("Comics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        if !vm.libraryPaths.contains(dest.path) { vm.addLibraryFolder(dest.path) }

        return urls.map { url in
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var target = dest.appendingPathComponent(url.lastPathComponent)
            var suffix = 1
            while FileManager.default.fileExists(atPath: target.path) {
                target = dest.appendingPathComponent(ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)")
                suffix += 1
            }
            do {
                try FileManager.default.copyItem(at: url, to: target)
                return target
            } catch {
                // Copy failed (disk full, permissions) -- fall back to the ephemeral picker URL
                // rather than dropping the import silently; `addSingle` already surfaces a
                // per-file failure reason if the path turns out to be unreadable.
                return url
            }
        }
    }
}

#endif
