import AISessionCore
import XCTest
@testable import AISessionRemote

final class DuplicateInTests: XCTestCase {
    func testMenuProposesDuplicate2() {
        XCTAssertEqual(DuplicateIn.proposedName(existingLabels: ["duplicate"]), "duplicate 2")
    }

    func testSummaryCancelDoesNotCallCreate() async {
        var calls = 0
        await DuplicateIn.perform(.cancelled) { calls += 1 }
        XCTAssertEqual(calls, 0)
    }

    func testCodexDuplicateCapturesAFreshSession() {
        let created = Conversation(
            id: "new", todoId: "t", computer: mac, cwd: "~", tool: "codex",
            tmuxName: "ai/codex/todo-t-2", sessionId: "", status: .unknown
        )
        XCTAssertEqual(
            DuplicateIn.followUp(plan: .start(text: "hello", label: "duplicate"), created: created),
            .captureFresh
        )
    }

    func testClaudeForkStoresTheForkedSession() {
        let created = Conversation(
            id: "new", todoId: "t", computer: mac, cwd: "~", tool: "claude",
            tmuxName: "ai/claude/todo-t-2", sessionId: "minted", status: .unknown
        )
        XCTAssertEqual(
            DuplicateIn.followUp(plan: .fork(sourceSessionId: "source", label: "duplicate"), created: created),
            .captureFork(sourceSessionId: "source")
        )
    }

    private let mac = Computer(id: "m", name: "Mac", hostname: "mac", username: "me")
}
