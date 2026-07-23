import SwiftUI

struct FilterBuilderView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var publisher: String = "Any"
    @State private var tag: String = "Any"
    @State private var writer: String = "Any"
    @State private var readStatus: String = "Any"
    @State private var yearMinText: String = ""
    @State private var yearMaxText: String = ""
    @State private var sortOrder: String = "Default"

    private let readStatusOptions = ["Any", "unread", "in_progress", "finished"]
    private func readStatusLabel(_ v: String) -> String {
        switch v {
        case "unread": return "Unread"
        case "in_progress": return "In Progress"
        case "finished": return "Finished"
        default: return "Any"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Smart Filter")
                .font(.title2.bold())
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 12)

            Form {
                Section {
                    TextField("Name", text: $name)
                }
                Section("Criteria") {
                    Picker("Publisher", selection: $publisher) {
                        Text("Any").tag("Any")
                        ForEach(vm.publishers, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Tag", selection: $tag) {
                        Text("Any").tag("Any")
                        ForEach(vm.allTags, id: \.tag.id) { Text($0.tag.name).tag($0.tag.name) }
                    }
                    Picker("Writer", selection: $writer) {
                        Text("Any").tag("Any")
                        ForEach(vm.writers, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Read Status", selection: $readStatus) {
                        ForEach(readStatusOptions, id: \.self) { Text(readStatusLabel($0)).tag($0) }
                    }
                    HStack {
                        TextField("Year from", text: $yearMinText)
                            .textFieldStyle(.roundedBorder)
                        Text("–")
                        TextField("Year to", text: $yearMaxText)
                            .textFieldStyle(.roundedBorder)
                    }
                    Picker("Sort", selection: $sortOrder) {
                        Text("Default").tag("Default")
                        ForEach(DatabaseManager.SortOrder.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(24)
        }
        .frame(width: 440, height: 520)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        vm.createSavedFilter(
            name: trimmedName,
            publisher: publisher == "Any" ? nil : publisher,
            tag: tag == "Any" ? nil : tag,
            writer: writer == "Any" ? nil : writer,
            readStatus: readStatus == "Any" ? nil : readStatus,
            yearMin: Int(yearMinText),
            yearMax: Int(yearMaxText),
            sortOrder: sortOrder == "Default" ? nil : sortOrder
        )
        dismiss()
    }
}
