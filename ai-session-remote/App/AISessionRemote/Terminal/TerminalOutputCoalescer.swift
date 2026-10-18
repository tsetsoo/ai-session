import Foundation

/// Batches bytes arriving on the SSH event loop into a single `feed()` per display frame.
///
/// Without this, every inbound SSH frame becomes its own main-thread dispatch and SwiftTerm
/// redraw. At high latency output arrives as fewer, larger bursts split across many frames,
/// so a single logical repaint would otherwise cost dozens of hops and dozens of redraws.
///
/// **Thread safety:** Safe to call `append` from any thread. `onFlush` callback is invoked on
/// whichever thread the injected `scheduleDrain` dispatches to. The `onFlush` property itself
/// is safe to assign at any time from any thread.
///
/// `scheduleDrain` is injected so tests can drive draining synchronously; production passes a
/// main-thread hop.
final class TerminalOutputCoalescer: @unchecked Sendable {
    /// Called on whichever thread `scheduleDrain` dispatches to. Safe to assign at any time.
    var onFlush: (([UInt8]) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onFlush
        }
        set {
            lock.lock()
            _onFlush = newValue
            lock.unlock()
        }
    }

    private let scheduleDrain: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var drainScheduled = false
    private var _onFlush: (([UInt8]) -> Void)?

    init(scheduleDrain: @escaping (@escaping () -> Void) -> Void) {
        self.scheduleDrain = scheduleDrain
    }

    /// Safe to call from any thread.
    func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }

        lock.lock()
        buffer.append(contentsOf: bytes)
        let needsSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()

        guard needsSchedule else { return }
        scheduleDrain { [weak self] in self?.drain() }
    }

    private func drain() {
        lock.lock()
        let pending = buffer
        let handler = _onFlush
        buffer.removeAll(keepingCapacity: true)
        drainScheduled = false
        lock.unlock()

        guard !pending.isEmpty else { return }
        handler?(pending)
    }
}
