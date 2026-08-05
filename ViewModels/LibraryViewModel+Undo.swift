import Foundation
import Combine
import CoreSpotlight
import os

extension LibraryViewModel {
    func offerUndo(_ message: String, undo: @escaping () -> Void) {
        undoDismissTask?.cancel()
        pendingUndo = UndoableAction(message: message, undo: undo)
        let task = DispatchWorkItem { [weak self] in self?.pendingUndo = nil }
        undoDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    func performUndo() {
        undoDismissTask?.cancel()
        pendingUndo?.undo()
        pendingUndo = nil
    }

    func dismissUndo() {
        undoDismissTask?.cancel()
        pendingUndo = nil
    }
}
