import XCTest
@testable import AISessionCore

final class TmuxCommandBuilderTests: XCTestCase {
    func testEnsureTmuxInstalledCheck() {
        let cmd = TmuxCommandBuilder.ensureTmuxInstalledCheck()
        XCTAssertTrue(cmd.contains("command -v tmux"))
        XCTAssertTrue(cmd.contains("/opt/homebrew/bin"))
        XCTAssertTrue(cmd.contains("$HOME/.local/bin"))
    }

    func testListSessions() {
        let cmd = TmuxCommandBuilder.listSessions()
        XCTAssertTrue(cmd.contains("tmux ls -F '#{session_name}\\t#{session_activity}\\t#{session_attached}'"))
        XCTAssertTrue(cmd.hasPrefix("export PATH="))
    }

    func testWhich() {
        let cmd = TmuxCommandBuilder.which(binary: "claude")
        XCTAssertTrue(cmd.contains("command -v 'claude'"))
        XCTAssertTrue(cmd.contains("/opt/homebrew/bin"))
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
        XCTAssertTrue(cmd.hasPrefix("export PATH="))
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
        let cmd = TmuxCommandBuilder.attach(tmuxName: "ai/claude/app")
        XCTAssertTrue(cmd.contains("tmux attach -t 'ai/claude/app'"))
        XCTAssertTrue(cmd.hasPrefix("export PATH="))
    }

    func testKillSession() {
        let cmd = TmuxCommandBuilder.killSession(tmuxName: "random")
        XCTAssertTrue(cmd.contains("tmux kill-session -t 'random'"))
        XCTAssertTrue(cmd.hasPrefix("export PATH="))
    }

    func testRenameSession() {
        XCTAssertTrue(
            TmuxCommandBuilder.renameSession(from: "random", to: "ai/claude/demo")
                .contains("tmux rename-session -t 'random' 'ai/claude/demo'")
        )
    }

    func testProbeBinaries() {
        let cmd = TmuxCommandBuilder.probeBinaries()
        XCTAssertTrue(cmd.contains("command -v tmux"))
        XCTAssertTrue(cmd.contains("command -v bash"))
        XCTAssertTrue(cmd.contains("claude:%s"))
    }

    func testWriteMetadata() {
        let cmd = TmuxCommandBuilder.writeMetadata(
            tmuxName: "ai/claude/sigma-revenue",
            json: #"{"tool":"claude"}"#
        )
        XCTAssertTrue(cmd.contains("mkdir -p ~/.ai-remote/sessions"))
        XCTAssertFalse(cmd.contains("'~/.ai-remote"))
        XCTAssertTrue(cmd.contains("> ~/.ai-remote/sessions/'ai__claude__sigma-revenue.json'"))
        XCTAssertTrue(cmd.contains("printf '%s'"))
        XCTAssertTrue(cmd.hasPrefix("export PATH="))
    }

    func testShellQuoteEscapesApostrophe() {
        XCTAssertEqual(TmuxCommandBuilder.shellQuote("it's"), "'it'\"'\"'s'")
    }

    func testListSessionsWithStatusesEmitsMarkerAndPreservesLsExitCode() {
        let command = TmuxCommandBuilder.listSessionsWithStatuses()
        XCTAssertTrue(command.contains("tmux ls -F"))
        XCTAssertTrue(command.contains("echo '\(RemoteScriptOutput.statusMarker)'"))
        // The script must exit with tmux ls's status so isNoServerError still fires.
        XCTAssertTrue(command.contains("exit $ls_exit"))
    }

    func testCreateSessionScriptUsesExitNinetyForMissingBinary() throws {
        // SessionName.init(tool:slug:) is failable, not throwing.
        let name = try XCTUnwrap(SessionName(tool: .claude, slug: "demo"))
        let command = TmuxCommandBuilder.createSession(
            name: name, cwd: "/tmp/demo", binary: "claude", metadataTemplate: "{\"cli\":[\"%s\"]}"
        )
        XCTAssertTrue(command.contains("command -v 'claude'"))
        XCTAssertTrue(command.contains("|| exit 90"))
        // exec so tmux's own exit code and stderr reach the client for duplicate detection.
        XCTAssertTrue(command.contains("exec tmux new-session -d -s 'ai/claude/demo'"))
        XCTAssertTrue(command.contains("-- \"$p\""))
    }

    func testCreateSessionScriptQuotesTemplateContainingSingleQuote() throws {
        let name = try XCTUnwrap(SessionName(tool: .claude, slug: "demo"))
        let command = TmuxCommandBuilder.createSession(
            name: name, cwd: "/tmp", binary: "claude", metadataTemplate: "{\"title\":\"it's\"}"
        )
        // shellQuote's '"'"' escape must appear so the quote cannot terminate the literal early.
        XCTAssertTrue(command.contains("'\"'\"'"))
    }

    func testPromoteSessionScriptMergesRenameAndMetadata() {
        let command = TmuxCommandBuilder.promoteSession(
            fromTmuxName: "old", toTmuxName: "ai/claude/demo", json: "{}"
        )
        XCTAssertTrue(command.contains("tmux rename-session -t 'old' 'ai/claude/demo'"))
        XCTAssertTrue(command.contains("printf '%s'"))
        XCTAssertTrue(command.contains("ai__claude__demo.json"))
    }
}
