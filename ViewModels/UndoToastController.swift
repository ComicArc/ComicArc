import Foundation

/// The generic "delete/bulk-delete/run-delete/tier-list-delete" undo-toast primitive -- one
/// pending action at a time, auto-dismissed after 8 seconds. Genuinely independent of library
/// data/navigation (previously mixed directly into `LibraryViewModel`), so it gets its own
/// object; `LibraryViewModel` composes one and exposes thin passthroughs so every existing call
/// site (`vm.offerUndo`, `vm.pendingUndo`, etc.) keeps working unchanged.
@MainActor
final class UndoToastController: ObservableObject {
    struct Action {
        let message: String
        let undo: () -> Void
    }

    @Published var pending: Action?
    private var dismissTask: DispatchWorkItem?

    func offer(_ message: String, undo: @escaping () -> Void) {
        dismissTask?.cancel()
        pending = Action(message: message, undo: undo)
        let task = DispatchWorkItem { [weak self] in self?.pending = nil }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    func perform() {
        dismissTask?.cancel()
        pending?.undo()
        pending = nil
    }

    func dismiss() {
        dismissTask?.cancel()
        pending = nil
    }
}
