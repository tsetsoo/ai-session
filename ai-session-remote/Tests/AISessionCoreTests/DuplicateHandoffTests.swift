import XCTest
@testable import AISessionCore

final class DuplicateHandoffTests: XCTestCase {
    private let mac = Computer(id: "m1", name: "Mac", hostname: "mac", username: "me")

    private func conversation(tool: String, sessionId: String) -> Conversation {
        Conversation(
            id: sessionId, todoId: "t", computer: mac, cwd: "~/x", tool: tool,
            tmuxName: "tmux-\(sessionId)", sessionId: sessionId, status: .idle
        )
    }

    func testClaudeDuplicateForks() {
        let transcript = String(repeating: "a", count: 120_001)
        XCTAssertEqual(
            DuplicateHandoff.decide(sourceTool: "claude", destinationTool: "claude", transcript: transcript),
            .fork
        )
        XCTAssertEqual(
            ForkCommand.arguments(tool: "claude", sessionId: "sess"),
            ["claude", "--resume", "sess", "--fork-session"]
        )
        XCTAssertNil(ForkCommand.arguments(tool: "codex", sessionId: "sess"))
        XCTAssertNil(ForkCommand.arguments(tool: "cursor", sessionId: "sess"))
    }

    func testCodexOverBudgetAsks() {
        let over = String(repeating: "a", count: 80_001)
        let exact = String(repeating: "a", count: 80_000)
        XCTAssertEqual(
            DuplicateHandoff.decide(sourceTool: "codex", destinationTool: "codex", transcript: over),
            .askForSummary
        )
        XCTAssertEqual(
            DuplicateHandoff.decide(sourceTool: "codex", destinationTool: "codex", transcript: exact),
            .sendTranscript
        )
    }

    func testHandoffUsesThePressedConversation() {
        let pressed = conversation(tool: "claude", sessionId: "pressed")
        _ = conversation(tool: "claude", sessionId: "decoy")
        XCTAssertEqual(
            DuplicateHandoff.plan(
                source: pressed, destinationTool: "claude", label: "duplicate",
                transcript: "ignored", confirmedSummary: nil
            ),
            .fork(sourceSessionId: "pressed", label: "duplicate")
        )
    }

    func testCancelBeforeStartCreatesNothing() {
        let source = conversation(tool: "codex", sessionId: "sess")
        XCTAssertEqual(
            DuplicateHandoff.plan(
                source: source, destinationTool: "cursor", label: "duplicate",
                transcript: String(repeating: "a", count: 80_001), confirmedSummary: nil
            ),
            .cancelled
        )
    }
}
