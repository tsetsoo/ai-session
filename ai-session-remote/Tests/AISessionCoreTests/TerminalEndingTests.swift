import XCTest
@testable import AISessionCore

final class TerminalEndingTests: XCTestCase {
    func testNoExitStatusIsALostConnection() {
        XCTAssertEqual(TerminalEnding(exitStatus: nil), .connectionLost)
    }

    func testZeroIsAFinishedSession() {
        XCTAssertEqual(TerminalEnding(exitStatus: 0), .finished)
    }

    func testOtherStatusesStopped() {
        XCTAssertEqual(TerminalEnding(exitStatus: 1), .stopped(1))
        XCTAssertEqual(TerminalEnding(exitStatus: 130), .stopped(130))
    }
}
