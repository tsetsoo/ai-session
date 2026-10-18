import XCTest
@testable import AISessionCore

final class CommandsTests: XCTestCase {
    private func conv(tool: String, cwd: String) -> Conversation {
        Conversation(todoId: "t", computer: Computer(id: "m", name: "M", hostname: "h", username: "u"),
                     cwd: cwd, tool: tool, tmuxName: "n", sessionId: "abc-123", status: .idle)
    }

    func testClaudeResumeKeepsTildeExpandable() {
        XCTAssertEqual(ResumeCommand.string(for: conv(tool: "claude", cwd: "~/code/my app")),
                       "cd ~/'code/my app' && claude --resume abc-123")
    }

    func testCodexResume() {
        XCTAssertEqual(ResumeCommand.string(for: conv(tool: "codex", cwd: "/srv/x")),
                       "cd '/srv/x' && codex resume abc-123")
    }

    func testCursorResumeUsesAgent() {
        XCTAssertEqual(ResumeCommand.string(for: conv(tool: "cursor", cwd: "~/programming/sigma-revenue")),
                       "cd ~/'programming/sigma-revenue' && agent --resume abc-123")
    }

    func testBareTildeAndQuoteEscaping() {
        XCTAssertEqual(ResumeCommand.string(for: conv(tool: "claude", cwd: "~")), "cd ~ && claude --resume abc-123")
        XCTAssertEqual(ResumeCommand.string(for: conv(tool: "claude", cwd: "/it's")),
                       "cd '/it'\\''s' && claude --resume abc-123")
    }

    func testInstall() {
        XCTAssertEqual(ResumeCommand.install(hubURL: "http://h:8080"),
                       "scripts/todo/install.sh --hub-url 'http://h:8080' --token \"$TODO_API_TOKEN\"")
    }

    func testOpenFailure() {
        XCTAssertEqual(OpenFailure(exitStatus: 127), .helpersMissing)
        XCTAssertEqual(OpenFailure(exitStatus: 90), .toolMissing)
        XCTAssertEqual(OpenFailure(exitStatus: 93), .folderMissing)
        XCTAssertEqual(OpenFailure(exitStatus: 94), .conversationNotFound)
        XCTAssertNil(OpenFailure(exitStatus: nil))
        XCTAssertNil(OpenFailure(exitStatus: 0))
        XCTAssertNil(OpenFailure(exitStatus: 1))
    }
}
