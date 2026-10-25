import AISessionCore
import XCTest
@testable import AISessionRemote

@MainActor
final class TodoRenameTests: XCTestCase {
    private let mac = DemoFixtures.macStudio

    func testTitleCollapsesWhitespaceAndIsOffWhenBlankOrUnchanged() {
        XCTAssertEqual(TodoRename.title(from: "  Fix the\n  parser ✓ ", current: "Old"), "Fix the parser ✓")
        XCTAssertNil(TodoRename.title(from: " \n\t ", current: "Old"))
        XCTAssertNil(TodoRename.title(from: "Old", current: "Old"))
        XCTAssertNil(TodoRename.title(from: "  Old ", current: "Old"))
    }

    func testOnlyStartedClaudeAndCodexConversationsAreRenamed() {
        func conversation(_ tool: String, _ sessionId: String) -> Conversation {
            var c = DemoFixtures.conversations[0]
            c.tool = tool
            c.sessionId = sessionId
            return c
        }
        let renamed = RemoteConversations.renamable([
            conversation("claude", "a"), conversation("codex", "b"), conversation("cursor", "c"), conversation("codex", ""),
        ])
        XCTAssertEqual(renamed.map(\.sessionId), ["a", "b"])
    }

    func testRenameExitCodes() {
        func error(_ code: Int32, _ stderr: String = "") -> Error? {
            do {
                try RemoteConversations.checkRename(SSHExecResult(exitCode: code, stdout: "", stderr: stderr), computerName: "mac-studio")
                return nil
            } catch { return error }
        }
        XCTAssertNil(error(0))
        XCTAssertNil(error(66), "a conversation that isn't on the computer has nothing to rename")
        XCTAssertTrue(error(64) is RemoteConversations.ScriptMissing, "scripts too old to know rename")
        XCTAssertTrue(error(127) is RemoteConversations.ScriptMissing)
        XCTAssertEqual(error(90, "codex not found") as? SSHRemoteError, .binaryMissing("codex"))
        XCTAssertNotNil(error(1, "codex couldn't rename x: no rollout found"))
    }

    func testDialogMessageCountsTheConversations() {
        XCTAssertNil(TodoRename.dialogMessage(renamableCount: 0))
        XCTAssertEqual(TodoRename.dialogMessage(renamableCount: 1), "Its conversation gets the same name.")
        XCTAssertEqual(TodoRename.dialogMessage(renamableCount: 3), "Its 3 conversations get the same name.")
    }

    func testConversationFailureSaysTheTodoWasRenamed() {
        XCTAssertEqual(
            TodoRename.conversationFailureMessage(SSHRemoteError.unreachable, computer: mac),
            "The todo has its new name, but its conversation on mac-studio kept the old one. "
                + "Can't reach mac-studio. Check it's awake and on Tailscale."
        )
    }
}
