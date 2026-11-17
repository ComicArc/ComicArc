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

/// The document picker's copies are temporary, so imported files are copied into the app's own
/// storage first.
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
                // If the copy fails, fall back to the picker's URL; addSingle reports a per-file
                // error if it's unreadable.
                return url
            }
        }
    }
}

#endif
