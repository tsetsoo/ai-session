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

    func testConcurrentAppendAndDrainProducesNoByteLoss() {
        // Thread-safe scheduler that queues drains to be executed
        let schedulerLock = NSLock()
        var pendingDrains: [() -> Void] = []
        let coalescer = TerminalOutputCoalescer { drain in
            schedulerLock.lock()
            pendingDrains.append(drain)
            schedulerLock.unlock()
        }

        // Thread-safe collection of flushed bytes
        let flushLock = NSLock()
        var totalBytesFlushed = 0
        coalescer.onFlush = { bytes in
            flushLock.lock()
            totalBytesFlushed += bytes.count
            flushLock.unlock()
        }

        let totalProducers = 5
        let bytesPerProducer = 20
        let expectedTotalBytes = totalProducers * bytesPerProducer

        // Multiple producers append concurrently
        DispatchQueue.concurrentPerform(iterations: totalProducers) { index in
            let startByte = UInt8(index * bytesPerProducer % 256)
            let bytes = Array(repeating: startByte, count: bytesPerProducer)
            coalescer.append(bytes)
        }

        // Drain all pending drains
        while true {
            schedulerLock.lock()
            let drain = pendingDrains.isEmpty ? nil : pendingDrains.removeFirst()
            schedulerLock.unlock()

            guard let drain = drain else { break }
            drain()
        }

        XCTAssertEqual(totalBytesFlushed, expectedTotalBytes, "no bytes should be lost")
    }
}
