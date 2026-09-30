import Foundation

extension LibraryViewModel {
    func offerUndo(_ message: String, undo: @escaping () -> Void) {
        undoToastController.offer(message, undo: undo)
    }
    /// A toast with no Undo button, for confirming something that didn't change anything.
    func showNotice(_ message: String) {
        undoToastController.offer(message, undo: nil)
    }
    func performUndo() { undoToastController.perform() }
    func dismissUndo() { undoToastController.dismiss() }
}
