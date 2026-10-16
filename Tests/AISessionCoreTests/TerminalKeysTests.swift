import XCTest
@testable import AISessionCore

final class TerminalKeysTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(TerminalKey.esc.bytes(tool: "claude"), [0x1B])
        XCTAssertEqual(TerminalKey.tab.bytes(tool: "claude"), [0x09])
        XCTAssertEqual(TerminalKey.left.bytes(tool: "claude"), [0x1B, 0x5B, 0x44])
        XCTAssertEqual(TerminalKey.up.bytes(tool: "claude"), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(TerminalKey.down.bytes(tool: "claude"), [0x1B, 0x5B, 0x42])
        XCTAssertEqual(TerminalKey.right.bytes(tool: "claude"), [0x1B, 0x5B, 0x43])
        XCTAssertEqual(TerminalKey.shiftEnter.bytes(tool: "claude"), [0x1B, 0x0D])
        XCTAssertEqual(TerminalKey.shiftEnter.bytes(tool: "codex"), [0x0A])
        XCTAssertEqual(TerminalKey.approve.bytes(tool: "claude"), [0x31])
        XCTAssertEqual(TerminalKey.approve.bytes(tool: "codex"), [0x79])
    }

    func testTypingDisarmsUntilNextWaiting() {
        var gate = ApproveGate()
        XCTAssertFalse(gate.isEnabled(tool: "claude"))
        gate.statusChanged(to: .waiting)
        XCTAssertTrue(gate.isEnabled(tool: "claude"))
        gate.userTyped()
        XCTAssertFalse(gate.isEnabled(tool: "claude"))
        gate.statusChanged(to: .waiting)
        XCTAssertFalse(gate.isEnabled(tool: "claude"))
        gate.statusChanged(to: .busy)
        gate.statusChanged(to: .waiting)
        XCTAssertTrue(gate.isEnabled(tool: "claude"))
        XCTAssertTrue(ApproveGate().isEnabled(tool: "codex"))
    }

    func testLeavingWaitingDisables() {
        for next in [ConversationStatus.busy, .idle] {
            var gate = ApproveGate()
            gate.statusChanged(to: .waiting)
            XCTAssertTrue(gate.isEnabled(tool: "claude"))
            gate.statusChanged(to: next)
            XCTAssertFalse(gate.isEnabled(tool: "claude"))
            XCTAssertTrue(gate.isEnabled(tool: "codex"))
        }
    }
}
