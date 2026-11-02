@testable import AISessionCore
import XCTest

final class ScheduledMarkerTests: XCTestCase {
    func testScheduledMarkerText() {
        XCTAssertEqual(ScheduledMarker.text(jobName: "Research"), "Scheduled · Research")
        XCTAssertEqual(ScheduledMarker.text(jobName: nil), "Scheduled")
        XCTAssertEqual(ScheduledMarker.text(jobName: "  "), "Scheduled")
    }

    func testTriggerSummary() {
        XCTAssertEqual(ScheduledMarker.triggerSummary(.cron("0 8 * * 1-5")), "Cron 0 8 * * 1-5")
        XCTAssertEqual(ScheduledMarker.triggerSummary(.manual), "Manual")
    }
}
