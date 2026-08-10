import SwiftUI

/// Shared by Run and TierList edit sheets -- identical except Run has an extra buy/info link
/// field, exposed here as an optional binding (`nil` hides it entirely, matching TierList).
struct EditCollectionView<T: NamedCollection>: View {
    let noun: String
    @Binding var item: T
    var buyLink: Binding<String>? = nil
    let onSave: (_ title: String, _ description: String, _ buyLink: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var buyLinkText: String

    init(noun: String, item: Binding<T>, buyLink: Binding<String>? = nil,
         onSave: @escaping (String, String, String?) -> Void) {
        self.noun = noun
        self._item = item
        self.buyLink = buyLink
        self.onSave = onSave
        _title = State(initialValue: item.wrappedValue.title)
        _description = State(initialValue: item.wrappedValue.description)
        _buyLinkText = State(initialValue: buyLink?.wrappedValue ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit \(noun)").font(.title2.bold()).padding(24)

            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description)
                    if buyLink != nil {
                        TextField("Buy / Info Link (URL)", text: $buyLinkText).autocorrectionDisabled()
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
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(24)
        }
        .frame(width: 400)
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        let d = description.trimmingCharacters(in: .whitespaces)
        let l = buyLink != nil ? buyLinkText.trimmingCharacters(in: .whitespaces) : nil
        onSave(t, d, l?.isEmpty == true ? nil : l)
        dismiss()
    }
}
