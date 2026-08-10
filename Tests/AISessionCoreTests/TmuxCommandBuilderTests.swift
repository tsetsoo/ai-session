import XCTest
@testable import AISessionCore

final class TmuxCommandBuilderTests: XCTestCase {
    func testEnsureTmuxInstalledCheck() {
        XCTAssertEqual(TmuxCommandBuilder.ensureTmuxInstalledCheck(), "command -v tmux")
    }

    func testListSessions() {
        XCTAssertEqual(TmuxCommandBuilder.listSessions(), "tmux ls -F '#{session_name}'")
    }

    func testWhich() {
        XCTAssertEqual(TmuxCommandBuilder.which(binary: "claude"), "command -v 'claude'")
    }

    func testNewSessionCommandQuotesCwd() {
        let name = SessionName(tool: .claude, slug: "app")!
        let cmd = TmuxCommandBuilder.newDetachedSession(
            name: name,
            cwd: "/Users/me/proj with spaces",
            commandArgs: ["claude"]
        )
        XCTAssertTrue(cmd.contains("tmux new-session -d"))
        XCTAssertTrue(cmd.contains("-s 'ai/claude/app'"))
        XCTAssertTrue(cmd.contains("-c '/Users/me/proj with spaces'"))
        XCTAssertTrue(cmd.contains("-- 'claude'"))
    }

    func testNewSessionCommandQuotesApostropheInArgs() {
        let name = SessionName(tool: .codex, slug: "test")!
        let cmd = TmuxCommandBuilder.newDetachedSession(
            name: name,
            cwd: "/tmp",
            commandArgs: ["it's"]
        )
        XCTAssertTrue(cmd.contains("'it'\"'\"'s'"))
    }

    func testAttach() {
        XCTAssertEqual(
            TmuxCommandBuilder.attach(tmuxName: "ai/claude/app"),
            "tmux attach -t 'ai/claude/app'"
        )
    }

    func testKillSession() {
        XCTAssertEqual(
            TmuxCommandBuilder.killSession(tmuxName: "random"),
            "tmux kill-session -t 'random'"
        )
    }

    func testWriteMetadata() {
        let cmd = TmuxCommandBuilder.writeMetadata(
            tmuxName: "ai/claude/sigma-revenue",
            json: #"{"tool":"claude"}"#
        )
        XCTAssertTrue(cmd.contains("mkdir -p '~/.ai-remote/sessions'"))
        XCTAssertTrue(cmd.contains("> '~/.ai-remote/sessions/ai__claude__sigma-revenue.json'"))
        XCTAssertTrue(cmd.contains("printf '%s'"))
    }

    func testShellQuoteEscapesApostrophe() {
        XCTAssertEqual(TmuxCommandBuilder.shellQuote("it's"), "'it'\"'\"'s'")
    }
}
