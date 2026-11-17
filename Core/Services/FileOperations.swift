import Foundation
import AppKit
import ZIPFoundation

/// Changes to comic files on disk. Every operation here is one the user explicitly asked for.
enum FileOperations {
    /// Moves a file to the system Trash. Returns its new location so it can be restored.
    static func moveToTrash(_ url: URL) -> URL? {
        var result: NSURL?
        do { try FileManager.default.trashItem(at: url, resultingItemURL: &result) } catch { return nil }
        return result as URL?
    }

    static func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Filename cleanup

    struct Rename: Identifiable, Hashable {
        var id: Int64 { comicID }
        let comicID: Int64
        let from: URL
        let to: URL
    }

    /// Proposed renames. Skips any whose new name collides with another file in the folder
    /// (compared case-insensitively, like the file system).
    static func proposedRenames(_ comics: [Comic]) -> (renames: [Rename], conflicts: Int) {
        var renames: [Rename] = []
        var conflicts = 0
        var taken = Set(comics.map { $0.filePath.lowercased() })
        for c in comics where FilenameCleanup.needsCleanup(c.filePath) {
            let to = c.url.deletingLastPathComponent().appendingPathComponent(FilenameCleanup.cleaned(c.url.lastPathComponent))
            let key = to.path.lowercased()
            if (taken.contains(key) && key != c.filePath.lowercased()) || FileManager.default.fileExists(atPath: to.path) && key != c.filePath.lowercased() {
                conflicts += 1
                continue
            }
            taken.insert(key)
            renames.append(Rename(comicID: c.id, from: c.url, to: to))
        }
        return (renames, conflicts)
    }

    /// Two-phase rename (everything to a temporary name first) so chains and swaps work. Returns
    /// the renames that succeeded; failures are moved back to their original names.
    static func apply(_ renames: [Rename]) -> [Rename] {
        let fm = FileManager.default
        var staged: [(Rename, URL)] = []
        for r in renames {
            let temp = r.from.deletingLastPathComponent().appendingPathComponent(".comicarc-rename-\(UUID().uuidString)")
            if (try? fm.moveItem(at: r.from, to: temp)) != nil { staged.append((r, temp)) }
        }
        var done: [Rename] = []
        for (r, temp) in staged {
            if !fm.fileExists(atPath: r.to.path), (try? fm.moveItem(at: temp, to: r.to)) != nil { done.append(r) }
            else { try? fm.moveItem(at: temp, to: r.from) }
        }
        return done
    }

    // MARK: - CBR to CBZ

    /// Re-encodes a CBR as a CBZ next to it and returns the new file's URL. The caller removes the
    /// original after updating the library.
    static func convertToCBZ(_ cbr: URL) throws -> URL {
        guard let unar = ExternalTool.path("unar") else { throw DocumentError.toolMissing }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("comicarc-convert-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let result = ExternalTool.run(unar, ["-quiet", "-no-directory", "-force-overwrite", "-output-directory", work.path, cbr.path])
        guard result.status == 0 else { throw DocumentError.cannotOpen }
        let files = (fm.enumerator(at: work, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { Documents.isPage($0.lastPathComponent) || $0.lastPathComponent.lowercased() == "comicinfo.xml" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard files.contains(where: { Documents.isPage($0.lastPathComponent) }) else { throw DocumentError.cannotOpen }
        let dest = cbr.deletingPathExtension().appendingPathExtension("cbz")
        guard !fm.fileExists(atPath: dest.path) else { throw CocoaError(.fileWriteFileExists) }
        let partial = dest.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        let archive = try Archive(url: partial, accessMode: .create, pathEncoding: nil)
        for file in files {
            let relative = String(file.path.dropFirst(work.path.count + 1))
            try archive.addEntry(with: relative, relativeTo: work, compressionMethod: .none)
        }
        try fm.moveItem(at: partial, to: dest)
        return dest
    }
}
