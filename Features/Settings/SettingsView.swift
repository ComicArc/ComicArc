import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            LibrarySettings().tabItem { Label("Library", systemImage: "books.vertical") }
            ReadingSettings().tabItem { Label("Reading", systemImage: "book") }
            DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }
            SyncSettings().tabItem { Label("Sync", systemImage: "ipad.and.iphone") }
        }
        .scenePadding()
    }
}

private struct AppearanceSettings: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ForEach(AppTheme.allCases) { ThemeSwatch(theme: $0) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } header: {
                Text("Theme")
            } footer: {
                Text("The reader always stays dark so pages stand out.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.comicInfoWriteBack) private var writeBack = false
    @State private var removing: String?

    var body: some View {
        Form {
            Section {
                ForEach(model.folders, id: \.self) { path in
                    HStack {
                        Image(systemName: FileManager.default.fileExists(atPath: path) ? "folder.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(FileManager.default.fileExists(atPath: path) ? Theme.accent : .orange)
                        VStack(alignment: .leading) {
                            Text((path as NSString).lastPathComponent)
                            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Remove") { removing = path }
                    }
                }
                HStack {
                    Button("Add Folder…") { if let url = ImportPanel.chooseFolder(message: "Choose a folder with comics") { model.addFolder(url) } }
                    Spacer()
                    Button("Scan Now") { model.rescan() }.disabled(model.folders.isEmpty || model.scan.running)
                }
            } header: { Text("Library Folders") } footer: {
                Text("ComicArc reads Publisher / Character / Series from your folders and watches them for new comics. Files are never moved or renamed unless you ask.")
            }
            Section("Metadata") {
                Toggle("Allow saving edits into CBZ files (ComicInfo.xml)", isOn: $writeBack)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove this folder?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Folder", role: .destructive) { if let r = removing { model.removeFolder(r) } }
        } message: { Text("Its comics leave your library (you can restore them from Trash). The files stay where they are.") }
    }
}

private struct ReadingSettings: View {
    @AppStorage(Prefs.defaultScrollMode) private var scrollMode = false
    @AppStorage(Prefs.autoplaySeconds) private var autoplay = 6.0

    var body: some View {
        Form {
            Section {
                Toggle("Use continuous scrolling for new series", isOn: $scrollMode)
                Picker("Autoplay speed", selection: $autoplay) {
                    ForEach([3.0, 5, 6, 8, 10, 15], id: \.self) { Text("\(Int($0)) seconds per page").tag($0) }
                }
            } footer: {
                Text("Fit, two-page spreads, right-to-left and scrolling are remembered for each series. Press ? while reading for shortcuts.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @State private var trash: [Comic] = []
    @State private var confirmErase = false
    @State private var confirmEmpty = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Export Backup…") { exportBackup() }
                    Button("Restore Backup…") { restoreBackup() }
                }
            } header: { Text("Backup") } footer: {
                Text("Saves progress, finished status, favorites, notes, tags, bookmarks, Reading Paths and your custom orders. Your comic files aren't included.")
            }
            Section("Trash (\(trash.count))") {
                if trash.isEmpty {
                    Text("Deleted and missing comics appear here.").foregroundStyle(.secondary)
                } else {
                    List(trash) { c in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(c.title).lineLimit(1)
                                Text(c.deletedReason == "missing" ? "File missing" : c.deletedReason == "folder_removed" ? "Folder removed" : "Deleted")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { Task { await model.restore([c.id]); await load() } }
                        }
                    }
                    .frame(height: 160)
                    Button("Empty Trash…", role: .destructive) { confirmEmpty = true }
                }
            }
            Section("Maintenance") {
                Button("Clear Cover Cache") {
                    Task { await CoverStore.shared.clearAll(); model.libraryDidChange(); message = "Covers will be rebuilt as you browse." }
                }
                Button("Erase Library…", role: .destructive) { confirmErase = true }
            }
        }
        .formStyle(.grouped)
        .task(id: model.revision) { await load() }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmEmpty) {
            Button("Empty Trash", role: .destructive) { model.perform { try await $0.purge(nil) } }
        } message: { Text("Removes \(trash.count) comics and their progress permanently. Files aren't touched.") }
        .confirmationDialog("Erase your whole library?", isPresented: $confirmErase) {
            Button("Erase Library", role: .destructive) {
                model.perform("Library erased") { try await $0.eraseLibrary() }
                Task { await CoverStore.shared.clearAll() }
            }
        } message: { Text("Removes every comic, all progress, tags and Reading Paths from ComicArc. Your comic files stay where they are. Export a backup first if you might want them back.") }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    private func load() async { trash = (try? await Database.shared.trashedComics()) ?? [] }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ComicArc Backup \(Date().formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await BackupService.export(to: url); message = "Backup saved." }
            catch { message = "Couldn't save the backup: \(error.localizedDescription)" }
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let s = try await BackupService.restore(from: url)
                model.libraryDidChange()
                message = "Restored \(s.comics) comics and \(s.paths) Reading Paths." + (s.unmatched > 0 ? " \(s.unmatched) comics in the backup weren't found in this library." : "")
            } catch { message = "That file isn't a ComicArc backup." }
        }
    }
}

private struct SyncSettings: View {
    @State private var sync = SyncService.shared

    var body: some View {
        Form {
            Section {
                Toggle("Look for nearby devices", isOn: Binding(get: { sync.isActive }, set: { $0 ? sync.start() : sync.stop() }))
                if sync.isActive {
                    if sync.peers.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Open ComicArc on your iPad, then choose Sync there.").foregroundStyle(.secondary) }
                    }
                    ForEach(sync.peers, id: \.self) { peer in
                        HStack {
                            Label(peer.displayName, systemImage: "ipad")
                            Spacer()
                            Button(sync.isSyncing ? "Syncing…" : "Sync") { sync.connect(peer) }.disabled(sync.isSyncing)
                        }
                    }
                }
                if let s = sync.summary { Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.finished) }
                if let e = sync.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            } header: { Text("Sync with iPad") } footer: {
                Text("Syncs reading progress and Reading Paths over your local network. No account, nothing leaves your network. Paths are merged, never deleted.")
            }
        }
        .formStyle(.grouped)
        .alert("Sync with \(sync.invitationFrom?.displayName ?? "device")?",
               isPresented: Binding(get: { sync.invitationFrom != nil }, set: { if !$0 { sync.respondToInvitation(accept: false) } })) {
            Button("Sync") { sync.respondToInvitation(accept: true) }
            Button("Not Now", role: .cancel) { sync.respondToInvitation(accept: false) }
        }
    }
}
