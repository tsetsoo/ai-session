import XCTest
@testable import AISessionRemote

final class TerminalOutputCoalescerTests: XCTestCase {
    func testManyAppendsProduceOneFlushInOrder() {
        var pendingDrain: (() -> Void)?
        let coalescer = TerminalOutputCoalescer { drain in pendingDrain = drain }
        var flushed: [[UInt8]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.append([1, 2])
        coalescer.append([3])
        coalescer.append([4, 5])

        XCTAssertTrue(flushed.isEmpty, "must not flush before the scheduled drain runs")
        pendingDrain?()

        XCTAssertEqual(flushed, [[1, 2, 3, 4, 5]])
    }

    func testSchedulesOnlyOncePerPendingDrain() {
        var scheduleCount = 0
        var pendingDrain: (() -> Void)?
        let coalescer = TerminalOutputCoalescer { drain in
            scheduleCount += 1
            pendingDrain = drain
        }
        coalescer.onFlush = { _ in }

        coalescer.append([1])
        coalescer.append([2])
        coalescer.append([3])

        XCTAssertEqual(scheduleCount, 1)
        pendingDrain?()

        coalescer.append([4])
        XCTAssertEqual(scheduleCount, 2, "a new drain is scheduled after the previous one ran")
    }

    func testDrainWithNoPendingBytesDoesNotFlush() {
        var pendingDrain: (() -> Void)?
        let coalescer = TerminalOutputCoalescer { drain in pendingDrain = drain }
        var flushCount = 0
        coalescer.onFlush = { _ in flushCount += 1 }

        coalescer.append([1])
        pendingDrain?()
        pendingDrain?()

        XCTAssertEqual(flushCount, 1)
    }
}
