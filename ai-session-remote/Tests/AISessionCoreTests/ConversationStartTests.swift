import XCTest
@testable import AISessionCore

final class ConversationStartTests: XCTestCase {
    func testNoHistoryPreselectsClaude() {
        XCTAssertEqual(ConversationStart.selectedTool(remembered: nil), "claude")
        XCTAssertEqual(ConversationStart.selectedTool(remembered: ""), "claude")
        XCTAssertEqual(ConversationStart.selectedTool(remembered: "shell"), "claude")
    }

    func testARememberedToolStaysSelected() {
        XCTAssertEqual(ConversationStart.selectedTool(remembered: "codex"), "codex")
        XCTAssertEqual(ConversationStart.selectedTool(remembered: "cursor"), "cursor")
    }

    func testAMissingConversationNeedsConfirm() {
        XCTAssertTrue(ConversationStart.needsConfirm(hasConversation: false))
        XCTAssertFalse(ConversationStart.needsConfirm(hasConversation: true))
        XCTAssertFalse(ConversationStart.hasStartedSession(nil))
        XCTAssertFalse(ConversationStart.hasStartedSession(""))
        XCTAssertTrue(ConversationStart.hasStartedSession("019f8b4e"))
    }

    /// Preselecting Claude is not a start. The tool step stays up until confirm.
    func testPreselectingClaudeDoesNotStart() {
        XCTAssertEqual(ConversationStart.selectedTool(remembered: nil), "claude")
        XCTAssertTrue(ConversationStart.needsConfirm(hasConversation: false))
    }

    func testCreatedLineIsTheNewSessionId() {
        XCTAssertEqual(ConversationStart.createdSessionId(from: "created 019f8b4e\n"), "019f8b4e")
        XCTAssertEqual(ConversationStart.createdSessionId(from: "created NEWCODX"), "NEWCODX")
        XCTAssertNil(ConversationStart.createdSessionId(from: "created\n"))
        XCTAssertNil(ConversationStart.createdSessionId(from: ""))
    }
}
