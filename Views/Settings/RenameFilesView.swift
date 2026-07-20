import SwiftUI

// MARK: - Rename Files to Match Library

// A guided, reviewable batch rename: shows exactly what would change before touching
// anything on disk, lets the user deselect individual files, and only ever renames within
// the same folder (never moves a file to a different directory) — folder placement is what
// LibraryScanner.folderComponents() uses for publisher/character/series, so a rename tool
// that also moved files around would be doing two very different things under one button.
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
                Text("Renames comic files on disk to \"Series #Issue\" — the format ComicArc reads most reliably. Folders are never moved, only the filename inside each one.")
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

    // MARK: - Logic

    private func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let comics = DatabaseManager.shared.allComics()
            var proposed: [(comic: Comic, newPath: String)] = []
            for comic in comics {
                let url = URL(fileURLWithPath: comic.filePath)
                let currentName = url.lastPathComponent
                let idealName = ComicFileNaming.idealFilename(
                    series: comic.series, issueNumber: comic.issueNumber,
                    title: comic.title, fileExtension: comic.fileExtension
                )
                guard currentName != idealName else { continue }
                let newPath = url.deletingLastPathComponent().appendingPathComponent(idealName).path
                proposed.append((comic, newPath))
            }
            // Two different comics landing on the same proposed filename (e.g. a duplicate,
            // or two issues whose issue numbers collide) would silently overwrite one another
            // on rename — flag as a conflict and leave both deselected rather than risk it.
            var pathCounts: [String: Int] = [:]
            for p in proposed { pathCounts[p.newPath, default: 0] += 1 }

            let results = proposed.map { p -> RenameCandidate in
                let conflict = (pathCounts[p.newPath] ?? 0) > 1
                return RenameCandidate(
                    comicId: p.comic.id,
                    oldPath: p.comic.filePath,
                    newPath: p.newPath,
                    conflict: conflict,
                    isSelected: !conflict
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
            var succeeded = 0
            var failed: [String] = []
            for candidate in toRename {
                let oldURL = URL(fileURLWithPath: candidate.oldPath)
                let newURL = URL(fileURLWithPath: candidate.newPath)
                do {
                    guard !FileManager.default.fileExists(atPath: newURL.path) else {
                        failed.append(candidate.oldName); continue
                    }
                    try FileManager.default.moveItem(at: oldURL, to: newURL)
                    DatabaseManager.shared.updateFilePath(id: candidate.comicId, newPath: newURL.path)
                    succeeded += 1
                } catch {
                    failed.append(candidate.oldName)
                }
                await MainActor.run { applyProgress += 1 }
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

    var id: Int64 { comicId }
    var oldName: String { URL(fileURLWithPath: oldPath).lastPathComponent }
    var newName: String { URL(fileURLWithPath: newPath).lastPathComponent }
}
