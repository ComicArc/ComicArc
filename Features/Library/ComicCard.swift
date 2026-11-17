import SwiftUI

/// A comic in a grid. Click opens its page; hovering shows a Read button. In selection mode a
/// click toggles selection. (No double-click: it would delay every single click.)
struct ComicCard: View {
    let comic: Comic
    var width: CGFloat = 168
    var showSeries = false
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var selected: Bool { model.selection.contains(comic.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CoverImage(comic)
                .coverFrame(width: width)
                .overlay(alignment: .bottom) {
                    if comic.isInProgress { ProgressLine(value: comic.progress).padding(6) }
                }
                .overlay(alignment: .topTrailing) { badges }
                .overlay(alignment: .topLeading) {
                    if model.selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2).symbolRenderingMode(.palette)
                            .foregroundStyle(selected ? Theme.onAccent : .white, selected ? Theme.accent : .black.opacity(0.35))
                            .padding(7)
                    }
                }
                .overlay {
                    if hovering && !model.selecting {
                        Button { model.open(comic) } label: {
                            Label(comic.isInProgress ? "Continue" : "Read", systemImage: "book.fill")
                        }
                        .buttonStyle(AccentButtonStyle())
                        .transition(.opacity)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner).stroke(Theme.accent, lineWidth: selected ? 3 : 0))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(showSeries ? comic.series : comic.shortLabel)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                HStack(spacing: 5) {
                    if let era = comic.folderGroup { EraTag(name: era) }
                    Text(showSeries ? comic.shortLabel : subtitle)
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if model.selecting { model.toggleSelection(comic.id) } else { model.path.append(.comic(comic.id)) }
        }
        .contextMenu { ComicMenu(comics: [comic]) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(comic.title), \(status)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Read") { model.open(comic) }
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 4) {
            if comic.isFavorite { badge("heart.fill", .pink) }
            if comic.isFinished { badge("checkmark", Theme.finished) }
        }
        .padding(6)
    }

    private func badge(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon).font(.system(size: 9, weight: .black)).foregroundStyle(.white)
            .frame(width: 20, height: 20).background(color, in: Circle()).shadow(radius: 2)
    }

    private var subtitle: String {
        if comic.isInProgress { return "Page \(comic.currentPage + 1) of \(comic.pageCount)" }
        if comic.isFinished { return "Read" }
        return "\(comic.pageCount) pages"
    }

    private var status: String {
        comic.isFinished ? "read" : comic.isInProgress ? "page \(comic.currentPage + 1) of \(comic.pageCount)" : "unread"
    }
}

/// Actions for one or more comics, shared by context menus and the selection bar.
struct ComicMenu: View {
    let comics: [Comic]
    @Environment(AppModel.self) private var model
    @State private var newPath = false

    private var one: Comic? { comics.count == 1 ? comics[0] : nil }

    var body: some View {
        if let c = one {
            Button(c.isInProgress ? "Continue Reading" : "Read") { model.open(c) }
            Button("Show Details") { model.path.append(.comic(c.id)) }
            Divider()
        }
        let allRead = comics.allSatisfy(\.isFinished)
        Button(allRead ? "Mark as Unread" : "Mark as Read") { allRead ? model.markUnread(comics) : model.markRead(comics) }
        let allFav = comics.allSatisfy(\.isFavorite)
        Button(allFav ? "Remove from Favorites" : "Add to Favorites") { model.setFavorite(comics, !allFav) }
        let allListed = comics.allSatisfy(\.inReadingList)
        Button(allListed ? "Remove from Reading List" : "Add to Reading List") { model.setReadingList(comics, !allListed) }
        AddToPathMenu(comics: comics)
        Divider()
        Button("Show in Finder") { FileOperations.revealInFinder(comics.map(\.url)) }
        if let c = one { ShareLink("Share…", item: c.url) }
        Divider()
        Button("Move to Trash", role: .destructive) { model.delete(comics) }
    }
}

/// "Add to Reading Path" submenu, including creating a new path on the spot.
struct AddToPathMenu: View {
    let comics: [Comic]
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu("Add to Reading Path") {
            ForEach(model.readingPaths.filter { !$0.isReadingList }) { p in
                Button(p.title) { model.addToPath(comics, pathID: p.id, title: p.title) }
            }
            if model.readingPaths.contains(where: { !$0.isReadingList }) { Divider() }
            Button("New Reading Path…") { NewPathPrompt.ask { model.addToNewPath(comics, title: $0) } }
        }
    }
}

/// A small name prompt that works from menus (SwiftUI alerts can't be presented from a menu item).
enum NewPathPrompt {
    @MainActor static func ask(title: String = "New Reading Path", placeholder: String = "Name",
                               initial: String = "", _ done: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { done(text) }
        }
    }
}

/// A responsive grid of comics.
struct ComicGrid: View {
    let comics: [Comic]
    var showSeries = false
    @AppStorage(Prefs.gridDensity) private var densityRaw = GridDensity.regular.rawValue

    var body: some View {
        let density = GridDensity(rawValue: densityRaw) ?? .regular
        LazyVGrid(columns: [GridItem(.adaptive(minimum: density.cardWidth, maximum: density.cardWidth), spacing: density.spacing)],
                  alignment: .leading, spacing: density.spacing + 4) {
            ForEach(comics) { ComicCard(comic: $0, width: density.cardWidth, showSeries: showSeries) }
        }
    }
}

/// Floating bar with actions for the selected comics.
struct SelectionBar: View {
    let visible: [Comic]
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var reassign = false

    private var chosen: [Comic] { visible.filter { model.selection.contains($0.id) } }

    var body: some View {
        HStack(spacing: 10) {
            Text(model.selection.isEmpty ? "Select comics" : "\(model.selection.count) selected")
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            Button("Select All") { model.selection = Set(visible.map(\.id)) }.buttonStyle(.link)
            Spacer(minLength: 16)
            Group {
                Button("Mark Read") { model.markRead(chosen) }
                Button("Mark Unread") { model.markUnread(chosen) }
                Menu("Add To") {
                    Button("Favorites") { model.setFavorite(chosen, true) }
                    Button("Reading List") { model.setReadingList(chosen, true) }
                    AddToPathMenu(comics: chosen)
                }
                .fixedSize()
                Button("Move to Series…") { reassign = true }
                Button("Move to Trash", role: .destructive) { confirmDelete = true }
            }
            .disabled(chosen.isEmpty)
            Button("Done") { model.endSelection() }.buttonStyle(AccentButtonStyle())
        }
        .controlSize(.regular)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .padding(.horizontal, 24)
        .confirmationDialog("Move \(chosen.count) comic\(chosen.count == 1 ? "" : "s") to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { model.delete(chosen) }
        } message: { Text("The files go to the system Trash. You can undo right after, or restore from Settings › Trash.") }
        .sheet(isPresented: $reassign) { ReassignSheet(comics: chosen) }
    }
}

/// Moves comics to another series and/or publisher, with Undo.
struct ReassignSheet: View {
    let comics: [Comic]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var series = ""
    @State private var publisher = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move \(comics.count) Comic\(comics.count == 1 ? "" : "s")").font(.title3.bold())
            TextField("Series (leave empty to keep)", text: $series)
            TextField("Publisher (leave empty to keep)", text: $publisher)
            Text("Moved comics keep their progress. This only changes how ComicArc files them, not the files themselves.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move") { apply(); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(series.trimmed.isEmpty && publisher.trimmed.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22).frame(width: 400)
    }

    private func apply() {
        let ids = comics.map(\.id)
        let before = Dictionary(uniqueKeysWithValues: comics.map { ($0.id, ($0.series, $0.publisher)) })
        let s = series.trimmed.isEmpty ? nil : series.trimmed
        let p = publisher.trimmed.isEmpty ? nil : publisher.trimmed
        Task {
            do {
                try await Database.shared.reassign(ids, series: s, publisher: p)
                model.endSelection()
                model.libraryDidChange()
                model.showToast("Moved \(ids.count) comic\(ids.count == 1 ? "" : "s")") {
                    for (id, old) in before { try? await Database.shared.reassign([id], series: old.0, publisher: old.1) }
                    model.libraryDidChange()
                }
            } catch { model.report(error) }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}


/// A comic's era (Classic, Modern…), taken from the folder it's in.
struct EraTag: View {
    let name: String
    var body: some View {
        Text(name.uppercased())
            .font(.system(size: 8.5, weight: .heavy, design: .rounded)).kerning(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 1))
            .fixedSize()
    }
    private var color: Color {
        switch name.lowercased() {
        case "classic": Theme.accent
        case "modern": Color(hex: 0x5AB0FF)
        default: Theme.textSecondary
        }
    }
}