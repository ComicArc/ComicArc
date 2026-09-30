import Foundation

/// The bottom-of-window toast: an undoable action ("… deleted — Undo") or, with no `undo`, a
/// plain notice. One at a time, auto-dismissed after 8 seconds. Genuinely independent of library
/// data/navigation (previously mixed directly into `LibraryViewModel`), so it gets its own
/// object; `LibraryViewModel` composes one and exposes thin passthroughs so every existing call
/// site (`vm.offerUndo`, `vm.pendingUndo`, etc.) keeps working unchanged.
@MainActor
final class UndoToastController: ObservableObject {
    struct Action {
        let message: String
        /// Nil for a plain notice -- the toast then shows no Undo button.
        let undo: (() -> Void)?
    }

    @Published var pending: Action?
    private var dismissTask: DispatchWorkItem?

    func offer(_ message: String, undo: (() -> Void)?) {
        dismissTask?.cancel()
        pending = Action(message: message, undo: undo)
        let task = DispatchWorkItem { [weak self] in self?.pending = nil }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    func perform() {
        dismissTask?.cancel()
        pending?.undo?()
        pending = nil
    }

    func dismiss() {
        dismissTask?.cancel()
        pending = nil
    }
}
