import SwiftUI

struct RenameFilesView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [RenameCandidate] = []
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var applyProgress = 0
    @State private var resultMessage: String?

    private var selectedCount: Int { candidates.filter(\.isSelected).count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                ProgressView("Scanning your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if candidates.isEmpty {
                emptyState
            } else {
                list
                Divider()
                footer
            }
        }
        #if os(macOS)
        .frame(width: 720, height: 560)
        #endif
        .task { load() }
        .alert("Rename Complete", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil; dismiss() } }
        )) {
            Button("Done") { resultMessage = nil; dismiss() }
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rename Files to Match Library").font(.title3.bold())
                Text("Renames comic files on disk to \"Series #Issue\" — the format ComicArc reads most reliably. Folders are never moved, only the filename inside each one. A checkmark means the name was verified against the offline comics database, not just guessed from the current filename.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Every file already matches").font(.headline).foregroundStyle(.secondary)
            Text("Nothing in your library needs renaming.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach($candidates) { $candidate in
                    HStack(spacing: 12) {
                        Toggle("", isOn: $candidate.isSelected)
                            .labelsHidden()
                            .disabled(candidate.conflict)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.oldName)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .strikethrough(candidate.isSelected)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                Text(candidate.newName)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(candidate.conflict ? .orange : Design.brandGold)
                                    .lineLimit(1)
                                if candidate.verified {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption2).foregroundStyle(.green)
                                        .help("Verified against the offline comics database")
                                }
                            }
                        }
                        Spacer()
                        if candidate.conflict {
                            Label("Conflicts with another file", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2).foregroundStyle(.orange)
                                .labelStyle(.iconOnly)
                                .help("Another comic would end up with this same name — skipped automatically")
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    Divider().padding(.leading, 20)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(selectedCount == candidates.filter({ !$0.conflict }).count ? "Deselect All" : "Select All") {
                let allSelected = selectedCount == candidates.filter({ !$0.conflict }).count
                for idx in candidates.indices where !candidates[idx].conflict {
                    candidates[idx].isSelected = !allSelected
                }
            }
            .buttonStyle(.plain).foregroundStyle(Design.brandBlue)

            Spacer()

            if isApplying {
                ProgressView(value: Double(applyProgress), total: Double(selectedCount))
                    .frame(width: 140)
                Text("\(applyProgress)/\(selectedCount)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(selectedCount) of \(candidates.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Rename \(selectedCount)…") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCount == 0)
            }
        }
        .padding(16)
    }

    private func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let comics = DatabaseManager.shared.allComics()
            var proposed: [(comic: Comic, newPath: String, verified: Bool)] = []
            for comic in comics {
                let url = URL(fileURLWithPath: comic.filePath)
                let currentName = url.lastPathComponent
                let idealName = ComicFileNaming.idealFilename(
                    series: comic.gcdSeriesName ?? comic.series,
                    issueNumber: comic.gcdIssueNumber ?? comic.issueNumber,
                    title: comic.title, fileExtension: comic.fileExtension
                )
                guard currentName != idealName else { continue }
                let newPath = url.deletingLastPathComponent().appendingPathComponent(idealName).path
                proposed.append((comic, newPath, comic.gcdSeriesName != nil))
            }

            // Keyed case-insensitively: macOS's default filesystems (APFS, HFS+) treat "Batman #1.cbz"
            // and "batman #1.cbz" as the same file, so a case-only difference is still a real
            // collision even though the two path strings aren't byte-for-byte equal.
            var pathCounts: [String: Int] = [:]
            for p in proposed { pathCounts[p.newPath.lowercased(), default: 0] += 1 }

            let results = proposed.map { p -> RenameCandidate in
                let conflict = (pathCounts[p.newPath.lowercased()] ?? 0) > 1
                return RenameCandidate(
                    comicId: p.comic.id,
                    oldPath: p.comic.filePath,
                    newPath: p.newPath,
                    conflict: conflict,
                    isSelected: !conflict,
                    verified: p.verified
                )
            }
            await MainActor.run {
                candidates = results.sorted { $0.oldName.localizedStandardCompare($1.oldName) == .orderedAscending }
                isLoading = false
            }
        }
    }

    private func apply() {
        let toRename = candidates.filter(\.isSelected)
        guard !toRename.isEmpty else { return }
        isApplying = true
        applyProgress = 0
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            // Two-phase rename: a file's target name can currently be occupied by ANOTHER file
            // that's also being renamed away in this same batch (e.g. two comics effectively
            // swapping names, or a chain of them). Renaming directly in one pass makes success
            // depend on arbitrary processing order -- whichever file happens to move out of the
            // way first. Moving everything to a unique temp name first guarantees every source
            // path is vacated before any final name is claimed, so ordering can't cause a failure.
            struct Staged { let comicId: Int64; let tempURL: URL; let finalURL: URL; let oldName: String }
            var staged: [Staged] = []
            var failed: [String] = []

            for candidate in toRename {
                let oldURL = URL(fileURLWithPath: candidate.oldPath)
                let tempURL = oldURL.deletingLastPathComponent()
                    .appendingPathComponent(".comicarc-rename-\(UUID().uuidString)")
                do {
                    try fm.moveItem(at: oldURL, to: tempURL)
                    staged.append(Staged(comicId: candidate.comicId, tempURL: tempURL,
                                          finalURL: URL(fileURLWithPath: candidate.newPath),
                                          oldName: candidate.oldName))
                } catch {
                    failed.append(candidate.oldName)
                }
                await MainActor.run { applyProgress += 1 }
            }

            var succeeded = 0
            for item in staged {
                do {
                    guard !fm.fileExists(atPath: item.finalURL.path) else {
                        // Genuinely occupied by something outside this batch -- move back so the
                        // file isn't left stranded under a temp name.
                        let revertURL = item.tempURL.deletingLastPathComponent().appendingPathComponent(item.oldName)
                        try? fm.moveItem(at: item.tempURL, to: revertURL)
                        failed.append(item.oldName); continue
                    }
                    try fm.moveItem(at: item.tempURL, to: item.finalURL)
                    DatabaseManager.shared.updateFilePath(id: item.comicId, newPath: item.finalURL.path)
                    succeeded += 1
                } catch {
                    failed.append(item.oldName)
                }
            }

            let finalSucceeded = succeeded
            let finalFailedCount = failed.count
            await MainActor.run {
                isApplying = false
                var message = "Renamed \(finalSucceeded) file\(finalSucceeded == 1 ? "" : "s")."
                if finalFailedCount > 0 {
                    message += " \(finalFailedCount) couldn't be renamed (in use or already existed)."
                }
                resultMessage = message
                vm.reload()
            }
        }
    }
}

private struct RenameCandidate: Identifiable {
    let comicId: Int64
    let oldPath: String
    let newPath: String
    let conflict: Bool
    var isSelected: Bool
    let verified: Bool

    var id: Int64 { comicId }
    var oldName: String { URL(fileURLWithPath: oldPath).lastPathComponent }
    var newName: String { URL(fileURLWithPath: newPath).lastPathComponent }
}
