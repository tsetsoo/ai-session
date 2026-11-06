@testable import AISessionCore
import XCTest

/// Restarting a conversation: the exact host command and what comes back.
final class RestartModelsTests: XCTestCase {
    private let sid = "0f3a9c21-1d4a-4e7b-8c55-2f0e8a1b7d90"

    func testStopOnlyCommand() {
        let command = TmuxCommandBuilder.restartConversation(tmuxName: "ai/claude/todo-0f3a9c21", sessionId: sid, tool: "claude")
        XCTAssertTrue(command.hasSuffix(#""$HOME/.ai-remote/bin/ai-todo-status" restart 'ai/claude/todo-0f3a9c21' '\#(sid)' 'claude'"#), command)
    }

    func testForceChromeAndReopenWithServers() {
        let command = TmuxCommandBuilder.restartConversation(
            tmuxName: "ai/claude/todo-a", sessionId: sid, tool: "claude", force: true, chrome: .on,
            reopenCwd: "~/my work", mcpServers: ["github", "sentry"])
        XCTAssertTrue(command.hasSuffix(" --force --chrome on --reopen '~/my work' --mcp 'github,sentry'"), command)
        // Codex has no Chrome; Cursor has no managed servers; no --mcp without a reopen.
        let codex = TmuxCommandBuilder.restartConversation(tmuxName: "ai/codex/todo-a", sessionId: sid, tool: "codex",
                                                           chrome: .on, reopenCwd: "/w", mcpServers: [])
        XCTAssertTrue(codex.hasSuffix(" --reopen '/w' --mcp ''"), codex)
        let cursor = TmuxCommandBuilder.restartConversation(tmuxName: "ai/cursor/todo-a", sessionId: sid, tool: "cursor",
                                                            reopenCwd: "/w", mcpServers: ["x"])
        XCTAssertTrue(cursor.hasSuffix(" --reopen '/w'"), cursor)
        let noReopen = TmuxCommandBuilder.restartConversation(tmuxName: "ai/claude/todo-a", sessionId: sid, tool: "claude",
                                                              mcpServers: ["x"])
        XCTAssertFalse(noReopen.contains("--mcp"))
    }

    func testResultsDecode() throws {
        let refused = try RestartResult.decode(Data(#"{"tmux":"t","session_id":"s","tool":"claude","before":"2.1.310","state":"busy","result":"refused","reason":"busy","message":"It's working on a turn."}"#.utf8))
        XCTAssertTrue(refused.isRefused)
        XCTAssertTrue(refused.canForce)
        let background = try RestartResult.decode(Data(#"{"result":"refused","reason":"background"}"#.utf8))
        XCTAssertFalse(background.canForce)
        let done = try RestartResult.decode(Data(#"{"result":"restarted","before":"2.1.310","after":"2.1.319","installed":"2.1.319","mode":"resumed","stopped":true}"#.utf8))
        XCTAssertEqual(done.after, "2.1.319")
        XCTAssertFalse(done.isRefused)
    }

    func testLaunchSettingsAndChromeChoice() throws {
        let settings = try LaunchSettings.decode(Data(#"{"chrome": true, "model": null, "permission_mode": "auto", "network": false, "args": ["--chrome"]}"#.utf8))
        XCTAssertEqual(settings.chrome, true)
        XCTAssertEqual(settings.permissionMode, "auto")
        XCTAssertEqual(ChromeChoice(saved: settings.chrome), .on)
        XCTAssertEqual(ChromeChoice(saved: nil), .default)
        XCTAssertEqual(ChromeChoice(saved: false), .off)
        XCTAssertTrue(TmuxCommandBuilder.launchSettings(tool: "claude", sessionId: sid)
            .hasSuffix(#""$HOME/.ai-remote/bin/ai-todo-status" launch show 'claude' '\#(sid)'"#))
    }
}
