import XCTest
@testable import AISessionCore

final class StatusMonitorSnapshotTests: XCTestCase {
    func testHeartbeatsUseHostClockAndIndependentRuntimeHealth() throws {
        let received = Date(timeIntervalSince1970: 10_000)
        let json = #"{"host_time_s":100,"codex":{"checked_ns":99000000000,"runtime_connected":true},"claude":{"checked_ns":99000000000,"runtime_connected":false}}"#
        let sample = try StatusMonitorSnapshot(data: Data(json.utf8), receivedAt: received)
        XCTAssertEqual(sample.confirmedAt(tool: "codex"), received.addingTimeInterval(-1))
        XCTAssertNil(sample.confirmedAt(tool: "claude"))
        XCTAssertNil(sample.confirmedAt(tool: "cursor"))
    }

    func testStaleMissingAndFutureHeartbeatsAreNotHealthy() throws {
        for pulse in ["null", #"{"checked_ns":90000000000,"runtime_connected":true}"#,
                      #"{"checked_ns":200000000000,"runtime_connected":true}"#] {
            let data = Data("{\"host_time_s\":100,\"codex\":\(pulse)}".utf8)
            XCTAssertNil(try StatusMonitorSnapshot(data: data, receivedAt: .now).confirmedAt(tool: "codex"))
        }
    }

    func testHealthyServiceDoesNotConfirmMissingOrStaleConversations() throws {
        let data = Data(#"{"host_time_s":100,"codex":{"checked_ns":99000000000,"runtime_connected":true},"codex_runtime":{"observed_ns":99000000000,"threads":{"loaded":["busy",null]}}}"#.utf8)
        let sample = try StatusMonitorSnapshot(data: data, receivedAt: .now)
        XCTAssertNotNil(sample.confirmedAt(tool: "codex", sessionID: "loaded"))
        XCTAssertNil(sample.confirmedAt(tool: "codex", sessionID: "unloaded"))
        let staleData = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"observed_ns\":99000000000",
                                                                                    with: "\"observed_ns\":80000000000").utf8)
        XCTAssertNil(try StatusMonitorSnapshot(data: staleData, receivedAt: .now).confirmedAt(tool: "codex", sessionID: "loaded"))
    }
}
