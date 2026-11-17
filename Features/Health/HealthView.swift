import SwiftUI

struct HealthView: View {
    @Environment(AppModel.self) private var model
    @State private var report: HealthReport?
    @State private var renaming = false
    @State private var converting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom) {
                    ScreenHeader(title: "Library Health", subtitle: subtitle)
                    Spacer()
                    Button { model.resync() } label: { Label("Resync Library", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(QuietButtonStyle()).disabled(model.scan.running)
                        .help("Re-reads series, publisher and issue numbers for every comic from its folder and filename")
                }
                if let r = report {
                    if r.issueCount == 0 {
                        Label("Everything looks good. No duplicates, unreadable files or metadata disagreements.", systemImage: "checkmark.seal.fill")
                            .font(.callout).foregroundStyle(Theme.finished)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !r.duplicateGroups.isEmpty { duplicates(r.duplicateGroups) }
                    if !r.conflicts.isEmpty { conflicts(r.conflicts) }
                    if !r.unreadable.isEmpty {
                        section("Unreadable Files", "These files have no readable pages. They may be damaged or still downloading.") {
                            ForEach(r.unreadable) { c in
                                HStack {
                                    Text(c.title).lineLimit(1)
                                    Spacer()
                                    Button("Show in Finder") { FileOperations.revealInFinder([c.url]) }.controlSize(.small)
                                    Button("Move to Trash") { model.delete([c]) }.controlSize(.small)
                                }
                            }
                        }
                    }
                    findings("Missing Issues", "Gaps in issue numbering. Big jumps (like a renumbering from #441 to #500) aren't counted.", r.missingIssues)
                    findings("More Than One #1", "Usually two volumes sharing a folder. Give each volume its own folder.", r.duplicateFirstIssues)
                    findings("Mixed Volumes", "ComicInfo.xml lists different volumes inside one series folder.", r.mixedVolumes)
                    section("Tools", nil) {
                        tool("Clean Up Filenames", r.renameCandidates == 0 ? "All filenames are tidy." :
                                "\(r.renameCandidates) filenames have underscores or extra spaces.", "textformat",
                             enabled: r.renameCandidates > 0) { renaming = true }
                        tool("Convert CBR to CBZ", r.cbrCount == 0 ? "No CBR files in your library." :
                                "\(r.cbrCount) CBR files. CBZ opens faster and supports writing metadata.", "doc.zipper",
                             enabled: r.cbrCount > 0) { converting = true }
                    }
                } else {
                    ProgressView("Checking your library…").frame(maxWidth: .infinity).padding(60)
                }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .task(id: model.revision) { report = try? await Database.shared.healthReport() }
        .sheet(isPresented: $renaming) { RenameSheet() }
        .sheet(isPresented: $converting) { ConvertSheet() }
    }

    private var subtitle: String {
        guard let r = report else { return "Checking…" }
        return r.issueCount == 0 ? "No problems found" : "\(r.issueCount) thing\(r.issueCount == 1 ? "" : "s") to look at"
    }

    private func duplicates(_ groups: [[Comic]]) -> some View {
        section("Duplicates", "Copies with the same file name, the same file, or an identical cover. Keep one; the rest move to the Trash.") {
            ForEach(groups, id: \.first!.id) { group in
                let keeper = group.max { ($0.pageCount, $0.isStarted ? 1 : 0) < ($1.pageCount, $1.isStarted ? 1 : 0) }!
                HStack(alignment: .top, spacing: 14) {
                    ForEach(group) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            CoverImage(c).coverFrame(width: 70)
                            Text(c.url.deletingLastPathComponent().lastPathComponent).font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            Text("\(c.pageCount) pages").font(.caption2).foregroundStyle(Theme.textTertiary)
                            if c.id == keeper.id { Text("Suggested").font(.caption2.bold()).foregroundStyle(Theme.accent) }
                        }
                        .frame(width: 90)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(group[0].title).font(.callout.weight(.medium)).lineLimit(1)
                        Button("Keep Suggested") { model.delete(group.filter { $0.id != keeper.id }) }.controlSize(.small)
                        Button("Show in Finder") { FileOperations.revealInFinder(group.map(\.url)) }.controlSize(.small)
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
    }

    private func conflicts(_ items: [MetadataConflict]) -> some View {
        section("Needs Review", "These comics' ComicInfo.xml disagrees with how they're filed. Nothing changes until you choose.") {
            ForEach(items) { c in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.comic.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text("\(c.field.replacingOccurrences(of: "_", with: " ").capitalized): “\(c.currentValue ?? "")” → “\(c.proposedValue ?? "")” (from \(c.source))")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Keep Current") { model.perform { try await $0.resolveConflict(c, apply: false) } }.controlSize(.small)
                    Button("Use ComicInfo") { model.perform { try await $0.resolveConflict(c, apply: true) } }.controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private func findings(_ title: String, _ note: String, _ items: [SeriesFinding]) -> some View {
        if !items.isEmpty {
            section(title, note) {
                ForEach(items) { f in
                    HStack {
                        PublisherBadge(publisher: f.publisher)
                        Text(f.series).font(.callout.weight(.medium))
                        Spacer()
                        Text(f.detail).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, _ note: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: title)
            if let note { Text(note).font(.caption).foregroundStyle(Theme.textSecondary) }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func tool(_ title: String, _ detail: String, _ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Review…", action: action).disabled(!enabled)
        }
    }
}

/// Previews filename cleanups, applies them, and offers Undo while open.
private struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renames: [FileOperations.Rename] = []
    @State private var conflicts = 0
    @State private var done: [FileOperations.Rename]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Clean Up Filenames").font(.title3.bold())
                Spacer()
                Button(done == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if done == nil { Button("Rename \(renames.count)") { apply() }.keyboardShortcut(.defaultAction).disabled(renames.isEmpty) }
            }
            .padding(18)
            if let done {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Renamed \(done.count) file\(done.count == 1 ? "" : "s").", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.finished)
                    Button("Undo All") { undo(done) }
                }
                .padding(18)
            } else {
                Text("Underscores become spaces and repeated spaces are collapsed. Nothing else about the names changes."
                     + (conflicts > 0 ? " \(conflicts) skipped because the new name is already taken." : ""))
                    .font(.caption).foregroundStyle(Theme.textSecondary).padding(.horizontal, 18)
                List(renames) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.from.lastPathComponent).strikethrough().foregroundStyle(Theme.textTertiary).lineLimit(1)
                        Text(r.to.lastPathComponent).lineLimit(1)
                    }
                    .font(.callout)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 620, height: 520)
        .task {
            let comics = (try? await Database.shared.comics(ComicFilter())) ?? []
            let plan = FileOperations.proposedRenames(comics)
            renames = plan.renames; conflicts = plan.conflicts
        }
    }

    private func apply() {
        let plan = renames
        Task {
            let succeeded = await Task.detached { FileOperations.apply(plan) }.value
            try? await Database.shared.write { db in
                try db.transaction { for r in succeeded { try db.run("UPDATE comics SET file_path = ?, title = ? WHERE id = ?",
                                                                     [r.to.path, r.to.deletingPathExtension().lastPathComponent, r.comicID]) } }
            }
            done = succeeded
            model.libraryDidChange()
        }
    }

    private func undo(_ renamed: [FileOperations.Rename]) {
        let back = renamed.map { FileOperations.Rename(comicID: $0.comicID, from: $0.to, to: $0.from) }
        Task {
            let restored = await Task.detached { FileOperations.apply(back) }.value
            try? await Database.shared.write { db in
                try db.transaction { for r in restored { try db.run("UPDATE comics SET file_path = ?, title = ? WHERE id = ?",
                                                                    [r.to.path, r.to.deletingPathExtension().lastPathComponent, r.comicID]) } }
            }
            model.libraryDidChange()
            model.showToast("Restored \(restored.count) original filenames")
            dismiss()
        }
    }
}

private struct ConvertSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var comics: [Comic] = []
    @State private var progress = 0
    @State private var running = false
    @State private var failures: [String] = []
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Convert CBR to CBZ").font(.title3.bold())
            Text("Each CBR is re-packed as a CBZ in the same folder, keeping its progress, tags and Reading Path entries. The original CBR moves to the Trash.")
                .font(.callout).foregroundStyle(Theme.textSecondary)
            if running || finished {
                ProgressView(value: Double(progress), total: Double(max(1, comics.count))).tint(Theme.accent)
                Text(finished ? "Converted \(comics.count - failures.count) of \(comics.count)." : "Converting \(progress + 1) of \(comics.count)…")
                    .font(.caption)
                if !failures.isEmpty { Text("Couldn't convert: " + failures.prefix(5).joined(separator: ", ")).font(.caption).foregroundStyle(.orange) }
            }
            HStack {
                Spacer()
                Button(finished ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                if !finished { Button("Convert \(comics.count)") { run() }.keyboardShortcut(.defaultAction).disabled(running || comics.isEmpty) }
            }
        }
        .padding(22).frame(width: 480)
        .task { comics = ((try? await Database.shared.comics(ComicFilter())) ?? []).filter { $0.fileExtension == "cbr" } }
    }

    private func run() {
        running = true
        Task {
            for (i, c) in comics.enumerated() {
                progress = i
                do {
                    let cbz = try await Task.detached { try FileOperations.convertToCBZ(c.url) }.value
                    let hash = LibraryScanner.fingerprint(cbz.path)
                    try await Database.shared.write { db in
                        try db.run("UPDATE comics SET file_path = ?, file_hash = ? WHERE id = ?", [cbz.path, hash, c.id])
                    }
                    _ = FileOperations.moveToTrash(c.url)
                } catch {
                    failures.append(c.title)
                }
            }
            progress = comics.count
            running = false; finished = true
            model.libraryDidChange()
        }
    }
}
