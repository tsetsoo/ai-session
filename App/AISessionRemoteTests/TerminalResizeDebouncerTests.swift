import XCTest
@testable import AISessionRemote

final class TerminalResizeDebouncerTests: XCTestCase {
    /// A manual scheduler: captures every scheduled callback instead of running it, so tests can
    /// fire them in whatever order they like and assert on what actually lands.
    private final class ManualScheduler {
        private(set) var scheduled: [() -> Void] = []

        var asScheduler: TerminalResizeDebouncer.Scheduler {
            { [weak self] work in self?.scheduled.append(work) }
        }

        func fireAll() {
            let pending = scheduled
            scheduled.removeAll()
            pending.forEach { $0() }
        }
    }

    func testFirstSizeChangeSchedulesAndSendsOnFire() {
        let scheduler = ManualScheduler()
        let debouncer = TerminalResizeDebouncer(scheduler: scheduler.asScheduler)
        var sent: [(Int, Int)] = []

        debouncer.sizeChanged(cols: 80, rows: 24) { cols, rows in sent.append((cols, rows)) }

        XCTAssertTrue(sent.isEmpty, "must not send before the scheduled work runs")
        scheduler.fireAll()

        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, 80)
        XCTAssertEqual(sent.first?.1, 24)
        XCTAssertEqual(debouncer.lastSentSize?.cols, 80)
        XCTAssertEqual(debouncer.lastSentSize?.rows, 24)
    }

    func testBurstOfSizeChangesOnlySendsTheSettledFinalSize() {
        // Rotation/keyboard show-hide fire sizeChanged several times across layout passes.
        // Only the last size reported before the debounce window elapses should ever be sent.
        let scheduler = ManualScheduler()
        let debouncer = TerminalResizeDebouncer(scheduler: scheduler.asScheduler)
        var sent: [(Int, Int)] = []

        debouncer.sizeChanged(cols: 80, rows: 24) { cols, rows in sent.append((cols, rows)) }
        debouncer.sizeChanged(cols: 81, rows: 24) { cols, rows in sent.append((cols, rows)) }
        debouncer.sizeChanged(cols: 82, rows: 25) { cols, rows in sent.append((cols, rows)) }

        XCTAssertEqual(scheduler.scheduled.count, 3, "each report schedules its own work item")
        scheduler.fireAll()

        XCTAssertEqual(sent.count, 1, "only the final, settled size must reach the host")
        XCTAssertEqual(sent.first?.0, 82)
        XCTAssertEqual(sent.first?.1, 25)
    }

    func testSizeMatchingLastSentIsSkippedEntirely() {
        let scheduler = ManualScheduler()
        let debouncer = TerminalResizeDebouncer(scheduler: scheduler.asScheduler)
        debouncer.noteSentSize(cols: 80, rows: 24)

        var sendCalled = false
        debouncer.sizeChanged(cols: 80, rows: 24) { _, _ in sendCalled = true }

        XCTAssertTrue(scheduler.scheduled.isEmpty, "no work should even be scheduled for a no-op resize")
        scheduler.fireAll()
        XCTAssertFalse(sendCalled)
    }

    func testSizeChangedAfterSettlingOnANewSizeIsNotSkipped() {
        let scheduler = ManualScheduler()
        let debouncer = TerminalResizeDebouncer(scheduler: scheduler.asScheduler)
        debouncer.noteSentSize(cols: 80, rows: 24)

        var sent: [(Int, Int)] = []
        debouncer.sizeChanged(cols: 100, rows: 40) { cols, rows in sent.append((cols, rows)) }
        scheduler.fireAll()

        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(debouncer.lastSentSize?.cols, 100)
        XCTAssertEqual(debouncer.lastSentSize?.rows, 40)

        // Reporting that same settled size again is now a no-op.
        var sendCalledAgain = false
        debouncer.sizeChanged(cols: 100, rows: 40) { _, _ in sendCalledAgain = true }
        scheduler.fireAll()
        XCTAssertFalse(sendCalledAgain)
    }

    func testNonPositiveSizeIsIgnored() {
        let scheduler = ManualScheduler()
        let debouncer = TerminalResizeDebouncer(scheduler: scheduler.asScheduler)

        debouncer.sizeChanged(cols: 0, rows: 24) { _, _ in XCTFail("must not send for a zero dimension") }
        debouncer.sizeChanged(cols: 80, rows: -1) { _, _ in XCTFail("must not send for a negative dimension") }

        XCTAssertTrue(scheduler.scheduled.isEmpty)
    }

    func testCancelPendingPreventsAStaleResizeFromFiringLater() {
        // Mirrors `TerminalCoordinator.disconnect()`: a resize gets debounced, then the session
        // goes away before the debounce window elapses. The stale work must not fire later and
        // land on whatever new session replaces it.
        let scheduler = ManualScheduler()
        let debouncer = TerminalResizeDebouncer(scheduler: scheduler.asScheduler)

        var sendCalled = false
        debouncer.sizeChanged(cols: 80, rows: 24) { _, _ in sendCalled = true }
        debouncer.cancelPending()
        scheduler.fireAll()

        XCTAssertFalse(sendCalled, "cancelled resize must not fire once its delay elapses")
    }

    func testNoteSentSizeAfterCancelDoesNotLeaveStaleState() {
        // After disconnect() cancels a pending resize, connect() on a fresh session records
        // whatever size the new PTY actually has — that must win over anything left behind by
        // the cancelled debounce, so a reused terminal is never left at a stale size.
        let scheduler = ManualScheduler()
        let debouncer = TerminalResizeDebouncer(scheduler: scheduler.asScheduler)

        debouncer.sizeChanged(cols: 80, rows: 24) { _, _ in }
        debouncer.cancelPending()
        debouncer.noteSentSize(cols: 120, rows: 40)
        scheduler.fireAll()

        XCTAssertEqual(debouncer.lastSentSize?.cols, 120)
        XCTAssertEqual(debouncer.lastSentSize?.rows, 40)
    }
}
