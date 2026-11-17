import Foundation

/// The bottom-of-window toast: an undoable action, or a plain notice when `undo` is nil. One at a
/// time, dismissed after 8 seconds.
@MainActor
final class UndoToastController: ObservableObject {
    struct Action {
        let message: String
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

extension LibraryViewModel {
    func offerUndo(_ message: String, undo: @escaping () -> Void) {
        undoToastController.offer(message, undo: undo)
    }
    /// A toast with no Undo button, for a plain confirmation.
    func showNotice(_ message: String) {
        undoToastController.offer(message, undo: nil)
    }
    func performUndo() { undoToastController.perform() }
    func dismissUndo() { undoToastController.dismiss() }
}
