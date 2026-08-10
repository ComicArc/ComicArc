import SwiftUI

/// Owns reader-presentation state: which comic (if any) is open in the reader overlay, and the
/// context it was opened with (a specific starting page, a run scope). Previously mixed directly
/// into `LibraryViewModel` alongside library data and navigation state -- genuinely independent
/// of both (nothing about "is the reader open" needs to know how the library grid is filtered,
/// and vice versa), so it gets its own object.
///
/// `LibraryViewModel` composes one (`readerCoordinator`) and exposes thin passthrough properties/
/// methods (`readerComic`, `openReader(_:)`, etc.) so every existing call site across the app
/// keeps working unchanged -- the ownership boundary is real, the migration is not a rename sweep.
@MainActor
final class ReaderCoordinator: ObservableObject {
    /// Set alongside `comic` when opening at a specific page (e.g. jumping to a favorite moment)
    /// rather than the comic's own saved resume position -- read once by ReaderView's init.
    /// `open(_:atPage:)`'s `nil` default means every ordinary open already resets this, so it
    /// can't leak a stale page onto the next comic.
    @Published var initialPage: Int? = nil
    /// Set alongside `comic` when opening from inside a Run's reading path, so the reader can
    /// offer run-scoped next/previous navigation instead of (or alongside) its normal series-
    /// based one. Carried forward automatically as the reader advances within the same run.
    @Published var runId: Int64? = nil
    @Published var comic: Comic? = nil {
        didSet {
            // The reader is presented as a ZStack overlay in ContentView, not a navigation push,
            // so RunDetailView never disappears/reappears around a read and is never otherwise
            // told its `items` snapshot (progress, "first unfinished"/Resume target) is now
            // stale. Broadcast on close so it can refresh.
            if oldValue != nil, comic == nil {
                NotificationCenter.default.post(name: .readerDidClose, object: nil)
            }
        }
    }

    func open(_ comic: Comic, atPage page: Int? = nil, runId: Int64? = nil) {
        withAnimation(Design.motion(Design.springGentle, reduce: Design.systemReduceMotionEnabled)) {
            self.initialPage = page; self.runId = runId; self.comic = comic
        }
    }

    func close() {
        withAnimation(Design.motion(Design.springGentle, reduce: Design.systemReduceMotionEnabled)) {
            comic = nil; initialPage = nil; runId = nil
        }
    }
}
