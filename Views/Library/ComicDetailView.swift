import SwiftUI

struct BulkReassignView: View {
    let count: Int
    let onApply: (_ series: String?, _ publisher: String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var series:    String = ""
    @State private var publisher: String = ""
    @State private var setSeries    = false
    @State private var setPublisher = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reassign \(count) Comic\(count == 1 ? "" : "s")")
                .font(.title2.bold())
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 4)
            Text("Correct a bad folder-derived series or publisher across the selected issues at once.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.bottom, 12)

            Form {
                Section {
                    Toggle("Set Series", isOn: $setSeries.animation())
                    if setSeries { TextField("Series", text: $series) }
                }
                Section {
                    Toggle("Set Publisher", isOn: $setPublisher.animation())
                    if setPublisher { TextField("Publisher", text: $publisher) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Apply") {
                    let s = series.trimmingCharacters(in: .whitespaces)
                    let p = publisher.trimmingCharacters(in: .whitespaces)
                    onApply(setSeries && !s.isEmpty ? s : nil, setPublisher && !p.isEmpty ? p : nil)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled((!setSeries || series.trimmingCharacters(in: .whitespaces).isEmpty)
                       && (!setPublisher || publisher.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            .padding(24)
        }
        .frame(width: 440)
    }
}

struct EditComicView: View {
    @Binding var comic: Comic
    @Environment(\.dismiss) private var dismiss

    @State private var title:       String
    @State private var series:      String
    @State private var publisher:   String
    @State private var issueNumber: String
    @State private var notes:       String

    init(comic: Binding<Comic>) {
        self._comic   = comic
        _title        = State(initialValue: comic.wrappedValue.title)
        _series       = State(initialValue: comic.wrappedValue.series)
        _publisher    = State(initialValue: comic.wrappedValue.publisher)
        _issueNumber  = State(initialValue: comic.wrappedValue.issueNumber ?? "")
        _notes        = State(initialValue: comic.wrappedValue.notes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Comic")
                .font(.title2.bold())
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 12)

            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Series", text: $series)
                    TextField("Publisher", text: $publisher)
                    TextField("Issue #", text: $issueNumber)
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(24)
        }
        .frame(width: 440)
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        let s = series.trimmingCharacters(in: .whitespaces).isEmpty ? "General" : series.trimmingCharacters(in: .whitespaces)
        let p = publisher.trimmingCharacters(in: .whitespaces).isEmpty ? "Unknown" : publisher.trimmingCharacters(in: .whitespaces)
        let i = issueNumber.trimmingCharacters(in: .whitespaces)
        let n = notes.trimmingCharacters(in: .whitespaces)

        LibraryViewModel.shared.updateMeta(comicId: comic.id, fields: [
            ("title",        t),
            ("series",       s),
            ("publisher",    p),
            ("issue_number", i.isEmpty ? nil : i),
            ("notes",        n.isEmpty ? nil : n)
        ])
        comic.title       = t
        comic.series      = s
        comic.publisher   = p
        comic.issueNumber = i.isEmpty ? nil : i
        comic.notes       = n.isEmpty ? nil : n

        LibraryViewModel.shared.reload()
        dismiss()
    }
}

struct ShelfChip: View {
    let shelf:    Shelf
    let isOn:     Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                if isOn { Image(systemName: "checkmark").font(.system(size: 9)) }
                Text(shelf.name).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isOn ? Design.brandBlue.opacity(0.25) : Design.surfaceBg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(isOn ? Design.brandBlue.opacity(0.5) : Design.borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct FlowLayout<T: Identifiable, Content: View>: View {
    let items:   [T]
    let spacing: CGFloat
    let content: (T) -> Content

    var body: some View {
        GeometryReader { geo in
            let rows = computeRows(width: geo.size.width)
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: spacing) {
                        ForEach(row) { item in content(item) }
                    }
                }
            }
        }
        .frame(minHeight: 28)
    }

    private func computeRows(width: CGFloat) -> [[T]] {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        #else
        let font = UIFont.systemFont(ofSize: UIFont.smallSystemFontSize)
        #endif
        var rows: [[T]] = [[]]
        var rowWidth: CGFloat = 0

        for item in items {
            let name: String
            if let t = item as? Tag { name = t.name }
            else if let s = item as? Shelf { name = s.name }
            else { name = "" }
            let textW  = (name as NSString).size(withAttributes: [.font: font]).width
            let itemW  = textW + 36 + spacing
            if rowWidth + itemW > width && !rows.last!.isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append(item)
            rowWidth += itemW
        }
        return rows.filter { !$0.isEmpty }
    }
}
