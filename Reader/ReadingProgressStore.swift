import Foundation

/// The rules for what reading position gets persisted, and when a page reached counts as genuine
/// progress vs. a jump. Formalizes the 2026-08-07 fix pass's `suppressCompletionCheck` flag
/// (previously duplicated as `@State` in both platform readers, threaded through six call sites
/// apiece) as a single, testable type shared by every platform. `@MainActor`: only ever driven
/// from `ReaderSession` (itself `@MainActor`), and its debounced work already runs via
/// `DispatchQueue.main`, so this matches actual usage rather than fighting it.
@MainActor
final class ReadingProgressStore {
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.25

    /// Where a reading session should resume -- clamped to the comic's current page count, which
    /// can shrink after a saved position (a metadata refresh, or a revival at the same path with
    /// a different file) and would otherwise land the reader on an unreachable blank page. Static
    /// and `nonisolated`: a pure function of the comic, touching no actor-isolated state, so it
    /// shouldn't inherit the class's `@MainActor` requirement (callers, including tests, can use
    /// it from anywhere).
    nonisolated static func resumePage(for comic: Comic) -> Int {
        min(max(0, comic.progress), max(0, comic.pageCount - 1))
    }

    /// Called on every page change. `isSequential` distinguishes genuine forward reading
    /// (`ReaderSession.advance()`, or continuous-scroll's own page-visibility tracking) from a
    /// jump (slider, page-jump, filmstrip tap, bookmark tap, Home/End) -- only the former can ever
    /// mark the issue finished. Resume position itself always updates regardless of source,
    /// including backward, since "put me back exactly where I left off" should hold even after a
    /// jump. Debounced uniformly (250ms) rather than the old implementation's inconsistent mix of
    /// synchronous-on-main for most paths and debounced only for the slider.
    func recordPosition(comic: Comic, page: Int, isSequential: Bool, onFinished: (() -> Void)? = nil) {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem {
            LibraryViewModel.shared.updateProgress(comic: comic, page: page)
            if isSequential, comic.pageCount > 1, page >= comic.pageCount - 1 {
                LibraryViewModel.shared.markFinished(comic: comic)
                onFinished?()
            }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Synchronous best-effort flush -- called on session teardown (dismiss, background,
    /// scenePhase change) so the debounce window above can't silently lose the very last position
    /// read before a crash or force-quit.
    func flush(comic: Comic, page: Int, isSequential: Bool) {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        LibraryViewModel.shared.updateProgress(comic: comic, page: page)
        if isSequential, comic.pageCount > 1, page >= comic.pageCount - 1 {
            LibraryViewModel.shared.markFinished(comic: comic)
        }
    }
}
