import SwiftUI

struct RenameFilesView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [RenameCandidate] = []
    @State private var unchangedCount = 0
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var applyProgress = 0
    @State private var report: RenameReport?

    private var selectedCount: Int { candidates.filter(\.isSelected).count }

    var body: some View {
        VStack(spacing: 0) {
            if let report {
                RenameResultsView(report: report) {
                    self.report = nil
                    dismiss()
                }
            } else {
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
        }
        #if os(macOS)
        .frame(width: 720, height: 560)
        #endif
        .task { load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fix Filenames").font(.title3.bold())
                Text("Cleans up filenames on disk: underscores become spaces, and repeated spaces collapse to one. It only tidies up what's already there — it doesn't rename files based on their metadata. Folders are never moved, only the filename inside each one.")
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
                            .accessibilityLabel("Rename \(candidate.oldName) to \(candidate.newName)")

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
        let selected = selectedCount
        let selectableCount = candidates.filter({ !$0.conflict }).count
        return HStack {
            Button(selected == selectableCount ? "Deselect All" : "Select All") {
                let allSelected = selectedCount == candidates.filter({ !$0.conflict }).count
                for idx in candidates.indices where !candidates[idx].conflict {
                    candidates[idx].isSelected = !allSelected
                }
            }
            .buttonStyle(.plain).foregroundStyle(Design.brandBlue)

            Spacer()

            if isApplying {
                ProgressView(value: Double(applyProgress), total: Double(selected))
                    .frame(width: 140)
                Text("\(applyProgress)/\(selected)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(selected) of \(candidates.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Rename \(selected)…") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == 0)
            }
        }
        .padding(16)
    }

    private func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let comics = DatabaseManager.shared.allComics()

            // Just a text cleanup of each comic's own current filename (underscores -> spaces,
            // collapsed whitespace) -- see `ComicFileNaming.cleanedFilename`.
            let idealNames = ComicFileNaming.idealFilenames(for: comics)

            var proposed: [(comic: Comic, newPath: String)] = []
            var unchanged = 0
            for comic in comics {
                guard let idealName = idealNames[comic.id] else { continue }
                let url = URL(fileURLWithPath: comic.filePath)
                guard url.lastPathComponent != idealName else { unchanged += 1; continue }
                let newPath = url.deletingLastPathComponent().appendingPathComponent(idealName).path
                proposed.append((comic, newPath))
            }

            // A collision here means two different files in the same folder would clean up to the
            // identical name -- keyed case-insensitively since macOS's default filesystems (APFS,
            // HFS+) treat "Batman #1.cbz" and "batman #1.cbz" as the same file.
            var pathCounts: [String: Int] = [:]
            for p in proposed { pathCounts[p.newPath.lowercased(), default: 0] += 1 }

            let results = proposed.map { p -> RenameCandidate in
                let conflict = (pathCounts[p.newPath.lowercased()] ?? 0) > 1
                return RenameCandidate(
                    comicId: p.comic.id,
                    oldPath: p.comic.filePath,
                    newPath: p.newPath,
                    conflict: conflict,
                    isSelected: !conflict
                )
            }
            let finalUnchanged = unchanged
            await MainActor.run {
                candidates = results.sorted { $0.oldName.localizedStandardCompare($1.oldName) == .orderedAscending }
                unchangedCount = finalUnchanged
                isLoading = false
            }
        }
    }

    private func apply() {
        let toRename = candidates.filter(\.isSelected)
        guard !toRename.isEmpty else { return }
        let skippedCount = candidates.count - toRename.count
        let unchangedSnapshot = unchangedCount
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
            struct Staged { let comicId: Int64; let tempURL: URL; let finalURL: URL; let oldName: String; let oldURL: URL }
            var staged: [Staged] = []
            var failedStaging: [RenameFailure] = []
            var succeededMoves: [RenameMove] = []

            for candidate in toRename {
                let oldURL = URL(fileURLWithPath: candidate.oldPath)
                let tempURL = oldURL.deletingLastPathComponent()
                    .appendingPathComponent(".comicarc-rename-\(UUID().uuidString)")
                do {
                    try fm.moveItem(at: oldURL, to: tempURL)
                    staged.append(Staged(comicId: candidate.comicId, tempURL: tempURL,
                                          finalURL: URL(fileURLWithPath: candidate.newPath),
                                          oldName: candidate.oldName, oldURL: oldURL))
                } catch {
                    failedStaging.append(RenameFailure(name: candidate.oldName,
                                                        reason: "Couldn't move the file: \(error.localizedDescription)"))
                }
                await MainActor.run { applyProgress += 1 }
            }

            var succeeded = 0
            var failedFinal: [RenameFailure] = []
            for item in staged {
                do {
                    guard !fm.fileExists(atPath: item.finalURL.path) else {
                        // Genuinely occupied by something outside this batch -- move back so the
                        // file isn't left stranded under a temp name.
                        let revertURL = item.tempURL.deletingLastPathComponent().appendingPathComponent(item.oldName)
                        try? fm.moveItem(at: item.tempURL, to: revertURL)
                        failedFinal.append(RenameFailure(name: item.oldName,
                                                          reason: "Another file already exists with the target name"))
                        continue
                    }
                    try fm.moveItem(at: item.tempURL, to: item.finalURL)
                    DatabaseManager.shared.updateFilePath(id: item.comicId, newPath: item.finalURL.path)
                    succeededMoves.append(RenameMove(comicId: item.comicId, oldPath: item.oldURL.path,
                                                      newPath: item.finalURL.path))
                    succeeded += 1
                } catch {
                    // The final move itself failed (e.g. the computed name is too long for the
                    // filesystem, the disk is full, or permissions changed mid-batch) -- move the
                    // file back to its original name rather than leaving it stranded under the
                    // hidden temp name with the DB still pointing at a path that no longer exists.
                    let revertURL = item.tempURL.deletingLastPathComponent().appendingPathComponent(item.oldName)
                    try? fm.moveItem(at: item.tempURL, to: revertURL)
                    failedFinal.append(RenameFailure(name: item.oldName,
                                                      reason: "Rename failed: \(error.localizedDescription)"))
                }
            }

            let finalReport = RenameReport.summarize(
                succeeded: succeeded, unchanged: unchangedSnapshot, skipped: skippedCount,
                failedStaging: failedStaging, failedFinal: failedFinal, succeededMoves: succeededMoves
            )
            await MainActor.run {
                isApplying = false
                report = finalReport
                vm.reload()
            }
        }
    }
}

private struct RenameResultsView: View {
    let report: RenameReport
    let onDone: () -> Void

    @EnvironmentObject var vm: LibraryViewModel
    @State private var isUndoing = false
    @State private var undone = false
    @State private var undoFailures: [RenameFailure] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename Complete").font(.title3.bold())

            HStack(spacing: 16) {
                StatPill(label: "Renamed", count: report.succeeded, color: .green)
                StatPill(label: "Unchanged", count: report.unchanged, color: .secondary)
                StatPill(label: "Skipped", count: report.skipped, color: .orange)
                StatPill(label: "Failed", count: report.totalFailed, color: .red)
            }

            if report.succeeded > 0 {
                HStack(spacing: 8) {
                    if undone {
                        Label("Reverted back to the original names", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(isUndoing ? "Reverting…" : "Undo All \(report.succeeded) Rename\(report.succeeded == 1 ? "" : "s")") {
                            undoAll()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isUndoing)
                        Text("Only available now, while this screen is still open.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if !undoFailures.isEmpty {
                    Text("\(undoFailures.count) file\(undoFailures.count == 1 ? "" : "s") couldn't be reverted (moved or renamed again since).")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }

            if report.totalFailed > 0 {
                DisclosureGroup("Failures (\(report.totalFailed))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.failedStaging + report.failedFinal, id: \.name) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                    Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(.top, 4)
            } else {
                Spacer(minLength: 0)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isUndoing)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Reverses every successful rename from this batch by moving each file back to its original
    /// name and pointing the comic's row back at that path -- only offered while this results
    /// screen is still on-screen (the batch's old/new paths aren't persisted anywhere after that),
    /// so this is a "changed your mind right now" safety net, not a general history/undo log.
    private func undoAll() {
        isUndoing = true
        let moves = report.succeededMoves
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var failures: [RenameFailure] = []
            for move in moves {
                let currentURL = URL(fileURLWithPath: move.newPath)
                let originalURL = URL(fileURLWithPath: move.oldPath)
                guard !fm.fileExists(atPath: originalURL.path) else {
                    failures.append(RenameFailure(name: currentURL.lastPathComponent,
                                                   reason: "Something already exists at the original path"))
                    continue
                }
                do {
                    try fm.moveItem(at: currentURL, to: originalURL)
                    DatabaseManager.shared.updateFilePath(id: move.comicId, newPath: originalURL.path)
                } catch {
                    failures.append(RenameFailure(name: currentURL.lastPathComponent,
                                                   reason: "Couldn't move it back: \(error.localizedDescription)"))
                }
            }
            // Snapshotting to a `let` right before crossing to the main actor -- `failures` is
            // still a mutable local from the loop above, and capturing it directly in this
            // closure is exactly the kind of mutable-var-across-isolation capture Swift 6 flags.
            let finalFailures = failures
            await MainActor.run {
                undoFailures = finalFailures
                isUndoing = false
                undone = true
                vm.reload()
            }
        }
    }
}

private struct StatPill: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)").font(.title2.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Design.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct RenameCandidate: Identifiable {
    let comicId: Int64
    let oldPath: String
    let newPath: String
    let conflict: Bool
    var isSelected: Bool

    var id: Int64 { comicId }
    var oldName: String { URL(fileURLWithPath: oldPath).lastPathComponent }
    var newName: String { URL(fileURLWithPath: newPath).lastPathComponent }
}

struct RenameFailure: Equatable {
    let name: String
    let reason: String
}

/// One completed rename, kept around only so "Undo All" on the results screen knows what to move
/// back where -- not persisted anywhere, so it only exists for the lifetime of that screen.
struct RenameMove: Equatable {
    let comicId: Int64
    let oldPath: String
    let newPath: String
}

/// Pure summary of a rename batch's outcome -- kept separate from the view so it's directly unit-
/// testable (Swift Testing, no simulator needed) rather than only exercisable by running the UI.
struct RenameReport: Equatable {
    let succeeded: Int
    let unchanged: Int
    let skipped: Int
    let failedStaging: [RenameFailure]
    let failedFinal: [RenameFailure]
    let succeededMoves: [RenameMove]

    var totalFailed: Int { failedStaging.count + failedFinal.count }

    static func summarize(
        succeeded: Int, unchanged: Int, skipped: Int,
        failedStaging: [RenameFailure], failedFinal: [RenameFailure], succeededMoves: [RenameMove] = []
    ) -> RenameReport {
        RenameReport(succeeded: succeeded, unchanged: unchanged, skipped: skipped,
                      failedStaging: failedStaging, failedFinal: failedFinal, succeededMoves: succeededMoves)
    }
}
