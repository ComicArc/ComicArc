import Foundation

extension LibraryViewModel {
    func offerUndo(_ message: String, undo: @escaping () -> Void) {
        undoToastController.offer(message, undo: undo)
    }
    func performUndo() { undoToastController.perform() }
    func dismissUndo() { undoToastController.dismiss() }
}
