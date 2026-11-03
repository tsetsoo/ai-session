@testable import AISessionRemote
import XCTest

final class RetryAfterTests: XCTestCase {
    func testARefusedFlagIsTriedAgainAfterTheInterval() {
        var memory = RetryAfter(interval: 300)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(memory.isBlocked("mac", now: start))
        memory.block("mac", now: start)
        XCTAssertTrue(memory.isBlocked("mac", now: start.addingTimeInterval(299)))
        XCTAssertFalse(memory.isBlocked("other", now: start.addingTimeInterval(1)))
        XCTAssertFalse(memory.isBlocked("mac", now: start.addingTimeInterval(300)), "updated helpers are used without a relaunch")
    }
}
