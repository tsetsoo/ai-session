import Foundation

/// Decides whether a `sizeChanged` report from `TerminalView` should produce a debounced
/// `window-change` to the remote PTY, and tracks the size last actually sent.
///
/// Keyboard show/hide and rotation fire `sizeChanged` several times across layout passes, and
/// each `window-change` makes tmux repaint the entire screen. By default this sends only the
/// settled size. Live updates instead send the latest size at a limited rate during a drag.
/// Both modes skip sizes that already match what was last sent.
///
/// Extracted out of `TerminalCoordinator` purely so this decision (and its debounce timing) can
/// be pinned with unit tests, without any UIKit/SwiftTerm scaffolding.
///
/// **Thread safety:** not internally synchronized. `TerminalCoordinator` only ever drives this
/// from the main thread — `TerminalViewDelegate.sizeChanged` is called by UIKit on the main
/// thread, and `connect()`/`disconnect()` are only ever invoked from SwiftUI's main-actor task
/// and lifecycle callbacks — so no lock is needed here.
final class TerminalResizeDebouncer {
    /// Given a callback, arranges for it to run once after the debounce window. Production
    /// passes a real `DispatchQueue.main.asyncAfter`; tests can invoke the callback synchronously
    /// or queue it up to drive by hand.
    typealias Scheduler = (@escaping () -> Void) -> Void

    private let scheduler: Scheduler
    private let liveUpdates: Bool
    private var pending: (cols: Int, rows: Int, send: (Int, Int) -> Void)?
    private var scheduled = false
    private(set) var lastSentSize: (cols: Int, rows: Int)?
    private var generation = 0

    init(scheduler: @escaping Scheduler, liveUpdates: Bool = false) {
        self.scheduler = scheduler
        self.liveUpdates = liveUpdates
    }

    /// Records a size as already known-current for the remote PTY, without scheduling or
    /// sending anything. Called right after `connect()` works out whether the live terminal
    /// size differs from what the PTY was already requested with.
    func noteSentSize(cols: Int, rows: Int) {
        lastSentSize = (cols, rows)
    }

    /// Reports a candidate size. Later reports replace a pending size; matching the last sent
    /// size cancels it. Live updates use a fixed window, while debounce restarts the window.
    func sizeChanged(cols: Int, rows: Int, send: @escaping (Int, Int) -> Void) {
        guard cols > 0, rows > 0 else { return }
        if liveUpdates {
            pending = lastSentSize == nil || lastSentSize! != (cols, rows) ? (cols, rows, send) : nil
            guard !scheduled, pending != nil else { return }
            scheduled = true
            let thisGeneration = generation
            scheduler { [weak self] in
                guard let self, self.generation == thisGeneration else { return }
                self.scheduled = false
                guard let pending = self.pending else { return }
                self.pending = nil
                self.lastSentSize = (pending.cols, pending.rows)
                pending.send(pending.cols, pending.rows)
            }
            return
        }
        // Even a return to the last sent size supersedes any pending different size.
        generation += 1
        guard lastSentSize == nil || lastSentSize! != (cols, rows) else { return }

        let thisGeneration = generation
        scheduler { [weak self] in
            guard let self, self.generation == thisGeneration else { return }
            self.lastSentSize = (cols, rows)
            send(cols, rows)
        }
    }

    /// Invalidates any resize currently scheduled so it becomes a no-op if it fires later. Call
    /// on disconnect: without this, a resize debounced for a session that's going away could
    /// still land — at a now-stale size — on whatever new session replaces it.
    func cancelPending() {
        generation += 1
        pending = nil
        scheduled = false
    }
}
