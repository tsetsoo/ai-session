import Foundation
import XCTest
@testable import AI_Session_Remote

final class TerminalConnectionDiagnosticsTests: XCTestCase {
    func testChannelFailureRetainsStageAndServerReason() {
        let cause = NSError(domain: "SSH", code: 4, userInfo: [NSLocalizedDescriptionKey: "Too many sessions"])
        let error = TerminalSetupFailure(stage: "Opening SSH terminal channel", underlying: cause)
        let details = TerminalConnectionDiagnostics.details(SSHChannelOpenFailure(underlying: error))
        XCTAssertTrue(details.contains("Opening SSH terminal channel"))
        XCTAssertTrue(details.contains("Too many sessions"))
        XCTAssertTrue(details.contains("SSH"))
    }

    func testWrappedFailureKeepsSameDetails() {
        let error = SSHTerminalSessionError.channelSetupFailed
        XCTAssertEqual(TerminalConnectionDiagnostics.details(SSHChannelOpenFailure(underlying: error)),
                       TerminalConnectionDiagnostics.details(error))
    }
}
