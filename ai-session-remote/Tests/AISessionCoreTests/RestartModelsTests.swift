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

    func testReopenRemakesItsWorktree() {
        let command = TmuxCommandBuilder.restartConversation(
            tmuxName: "ai/claude/todo-a", sessionId: sid, tool: "claude", reopenCwd: "~/.ai-remote/worktrees/p/c",
            mcpServers: nil, worktree: (folder: "~/programming/app", branch: "ai/fix-c"))
        XCTAssertTrue(command.hasSuffix(" --reopen '~/.ai-remote/worktrees/p/c' --worktree '~/programming/app' 'ai/fix-c'"), command)
        let noReopen = TmuxCommandBuilder.restartConversation(
            tmuxName: "ai/claude/todo-a", sessionId: sid, tool: "claude", worktree: (folder: "~/r", branch: "b"))
        XCTAssertFalse(noReopen.contains("--worktree"))
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

    func testRestartBatchSummary() throws {
        func result(_ json: String) throws -> RestartResult { try RestartResult.decode(Data(json.utf8)) }
        var batch = RestartBatch()
        XCTAssertEqual(batch.summary, "Restarted 0.")
        try batch.add(result(#"{"result":"restarted","before":"2.1.310","after":"2.1.319"}"#), title: "A")
        try batch.add(result(#"{"result":"restarted"}"#), title: "B")
        try batch.add(result(#"{"result":"refused","reason":"busy","message":"It's working on a turn."}"#), title: "C")
        XCTAssertEqual(batch.summary, "Restarted 2. Left 1 that was working, waiting or running background tasks.")
        try batch.add(result(#"{"result":"refused","reason":"background"}"#), title: "D")
        try batch.add(result(#"{"result":"failed","stage":"reopen","message":"Starting it again failed: x."}"#), title: "E")
        batch.addFailure("No connection.", title: "F")
        var unread = RestartBatch()
        try unread.add(result(#"{"result":"refused","reason":"unknown"}"#), title: "G")
        XCTAssertEqual(unread.summary, "Restarted 0. Left 1 whose state couldn't be read; restart it from its row if it's idle.")
        XCTAssertEqual([batch.restarted, batch.left, batch.failures.count], [2, 2, 2])
        XCTAssertEqual(batch.summary, "Restarted 2. Left 2 that were working, waiting or running background tasks. "
            + "2 failed: E: Starting it again failed: x.; F: No connection.")
    }
}
