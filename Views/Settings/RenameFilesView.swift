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
                Text("Rename Files to Match Library").font(.title3.bold())
                Text("Renames comic files on disk to ComicArc's canonical format — \"Series (Edition) #Issue\" — so every file is named consistently no matter its publisher or series. Folders are never moved, only the filename inside each one. A checkmark means the name was verified against the offline comics database, not just guessed from the current filename.")
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

            // Resolves one canonical GCD name per (publisher, series) group (so a comic whose own
            // GCD match failed still gets the same real name as its matched siblings, instead of
            // being locked into a folder-derived abbreviation forever) and disambiguates the whole
            // batch up front, so comics that would otherwise reduce to the identical proposed name
            // (annuals/specials/TPBs with no parsed issue number, or same-numbered issues from a
            // different volume) get a meaningful disambiguator instead of colliding and getting
            // silently skipped below. See `ComicFileNaming.idealFilenames` for the full algorithm.
            let idealNames = ComicFileNaming.idealFilenames(for: comics)

            var proposed: [(comic: Comic, newPath: String, verified: Bool)] = []
            var unchanged = 0
            for comic in comics {
                guard let idealName = idealNames[comic.id] else { continue }
                let url = URL(fileURLWithPath: comic.filePath)
                guard url.lastPathComponent != idealName else { unchanged += 1; continue }
                let newPath = url.deletingLastPathComponent().appendingPathComponent(idealName).path
                proposed.append((comic, newPath, comic.gcdSeriesName != nil))
            }

            // Any collision remaining here is a genuine cross-series coincidence or a true
            // same-issue duplicate file -- disambiguatedFilenames already resolved every
            // same-bare-name collision above, so this is just the existing safety net for
            // whatever's left, keyed case-insensitively since macOS's default filesystems
            // (APFS, HFS+) treat "Batman #1.cbz" and "batman #1.cbz" as the same file.
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
            struct Staged { let comicId: Int64; let tempURL: URL; let finalURL: URL; let oldName: String }
            var staged: [Staged] = []
            var failedStaging: [RenameFailure] = []

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
                failedStaging: failedStaging, failedFinal: failedFinal
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename Complete").font(.title3.bold())

            HStack(spacing: 16) {
                StatPill(label: "Renamed", count: report.succeeded, color: .green)
                StatPill(label: "Unchanged", count: report.unchanged, color: .secondary)
                StatPill(label: "Skipped", count: report.skipped, color: .orange)
                StatPill(label: "Failed", count: report.totalFailed, color: .red)
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
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    let verified: Bool

    var id: Int64 { comicId }
    var oldName: String { URL(fileURLWithPath: oldPath).lastPathComponent }
    var newName: String { URL(fileURLWithPath: newPath).lastPathComponent }
}

struct RenameFailure: Equatable {
    let name: String
    let reason: String
}

/// Pure summary of a rename batch's outcome -- kept separate from the view so it's directly unit-
/// testable (Swift Testing, no simulator needed) rather than only exercisable by running the UI.
struct RenameReport: Equatable {
    let succeeded: Int
    let unchanged: Int
    let skipped: Int
    let failedStaging: [RenameFailure]
    let failedFinal: [RenameFailure]

    var totalFailed: Int { failedStaging.count + failedFinal.count }

    static func summarize(
        succeeded: Int, unchanged: Int, skipped: Int,
        failedStaging: [RenameFailure], failedFinal: [RenameFailure]
    ) -> RenameReport {
        RenameReport(succeeded: succeeded, unchanged: unchanged, skipped: skipped,
                      failedStaging: failedStaging, failedFinal: failedFinal)
    }
}
