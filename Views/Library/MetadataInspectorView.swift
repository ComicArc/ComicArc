import SwiftUI

struct MetadataInspectorView: View {
    let comicId: Int64
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: LibraryViewModel
    @State private var info: DatabaseManager.MetadataInspectorInfo?
    @State private var proposedName: String?
    @State private var isRenaming = false
    @State private var renameError: String?
    @State private var showGCDPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Metadata Inspector").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.escape)
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 12)

            if let info {
                Form {
                    Section("What ComicArc Uses") {
                        row("Title", info.comic.title)
                        row("Publisher", info.comic.publisher)
                        row("Series", info.comic.series)
                        row("Character", info.comic.character)
                        row("Issue Number", info.comic.issueNumber)
                    }

                    Section("Reading Order") {
                        row("Comic Type", info.comicType.rawValue)
                        row("Legacy Number", info.legacyNumber.map { formatNumber($0) })
                        row("Position", "\(info.comic.readingOrderPosition ?? info.comic.position)")
                        row("Confidence", info.comic.readingOrderConfidence.map { "\($0)%" })
                        row("Reason", info.comic.readingOrderReason)
                    }

                    Section("ComicInfo.xml") {
                        if info.hasComicInfo == false {
                            Text("No ComicInfo.xml metadata was found for this file.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if info.hasComicInfo == nil {
                            Text("Scanned before ComicArc tracked whether ComicInfo.xml was present — resync to find out.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        row("Writer", info.comic.writer)
                        row("Penciller", info.comic.penciller)
                        row("Story Arc", info.comic.storyArc)
                        row("Story Arc Number", info.storyArcNumber)
                        row("Volume", info.comic.volume)
                        row("Format", info.comic.format)
                        row("Series Group", info.seriesGroup)
                        row("Alternate Number", info.alternateNumber)
                        row("ComicInfo Issue Number", info.comicInfoIssueNumber)
                        row("Publication Date", publicationDate(info))
                    }

                    Section("Offline Comics Database Match") {
                        if info.comic.gcdMatchConfidence != nil {
                            row("Matched Series", info.comic.gcdSeriesName)
                            row("Matched Issue", info.comic.gcdIssueNumber)
                            row("Confidence", info.comic.gcdMatchConfidence.map { "\($0)%" })
                            row("Reason", info.gcdMatchReason)
                        } else {
                            Text("No match found in the offline comics database.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button(info.comic.gcdMatchConfidence != nil ? "Fix Match…" : "Find Match…") {
                            showGCDPicker = true
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }

                    Section("Duplicate Matching") {
                        if info.duplicateMatchCount > 0 {
                            row("Other Matching Copies", "\(info.duplicateMatchCount)")
                            Text("Sharing the same publisher, series, issue number, and comic type.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No other comic shares this publisher, series, issue number, and comic type.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Section("File") {
                        row("Path", info.comic.filePath)
                        row("File Hash", info.comic.fileHash)
                        row("Pages", "\(info.comic.pageCount)")
                        if let proposedName {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Filename doesn't match the library", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                Text(proposedName)
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                Button(isRenaming ? "Renaming…" : "Rename File to Match") { renameFile(to: proposedName) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .disabled(isRenaming)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 480, height: 600)
        .task { await load() }
        .sheet(isPresented: $showGCDPicker) {
            GCDMatchPickerView(comicId: comicId, currentSeries: info?.comic.series ?? "",
                               currentGCDMatchSource: info?.gcdMatchSource ?? "auto") {
                Task { await load(); vm.reload() }
            }
            .environmentObject(vm)
        }
        .alert("Couldn't Rename File", isPresented: Binding(
            get: { renameError != nil },
            set: { if !$0 { renameError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameError ?? "")
        }
    }

    private func load() async {
        let id = comicId
        let (fetchedInfo, fetchedProposal) = await Task.detached(priority: .userInitiated) {
            (DatabaseManager.shared.metadataInspectorInfo(comicId: id), DatabaseManager.shared.proposedFilename(comicId: id))
        }.value
        info = fetchedInfo
        proposedName = fetchedProposal
    }

    private func renameFile(to newName: String) {
        isRenaming = true
        let id = comicId
        Task.detached(priority: .userInitiated) {
            guard let oldPath = DatabaseManager.shared.filePath(forComicId: id) else {
                await MainActor.run { isRenaming = false; renameError = "This file is no longer in the library." }
                return
            }
            let oldURL = URL(fileURLWithPath: oldPath)
            let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
            let fm = FileManager.default
            guard !fm.fileExists(atPath: newURL.path) else {
                await MainActor.run {
                    isRenaming = false
                    renameError = "Another file already exists with that name."
                }
                return
            }
            do {
                try fm.moveItem(at: oldURL, to: newURL)
                DatabaseManager.shared.updateFilePath(id: id, newPath: newURL.path)
            } catch {
                await MainActor.run { isRenaming = false; renameError = error.localizedDescription }
                return
            }
            await MainActor.run { vm.reload() }
            await load()
            await MainActor.run { isRenaming = false }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        }
    }

    private func publicationDate(_ info: DatabaseManager.MetadataInspectorInfo) -> String? {
        guard let year = info.comic.year else { return nil }
        var parts = ["\(year)"]
        if let month = info.coverMonth { parts.append(String(format: "%02d", month)) }
        if let day = info.coverDay { parts.append(String(format: "%02d", day)) }
        return parts.joined(separator: "-")
    }

    private func formatNumber(_ n: Double) -> String {
        n == n.rounded(.towardZero) ? String(Int(n)) : String(n)
    }
}
