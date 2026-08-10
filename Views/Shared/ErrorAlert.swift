import SwiftUI

extension View {
    /// The "show a dismissible error alert from a `Binding<String?>`" boilerplate -- was
    /// independently duplicated (title varying, mechanics identical) across 8 files:
    /// `.alert(title, isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }))
    /// { Button("OK", role: .cancel) {} } message: { Text(message ?? "") }`.
    /// Doesn't own the error state itself -- each call site keeps its own local `@State private
    /// var xError: String?`, set wherever the failure actually happens; this only standardizes
    /// how it's *shown*.
    func errorAlert(_ title: String, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
