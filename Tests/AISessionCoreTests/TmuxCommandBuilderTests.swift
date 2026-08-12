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

    func testProbeBinaries() {
        let cmd = TmuxCommandBuilder.probeBinaries()
        XCTAssertTrue(cmd.contains("command -v tmux"))
        XCTAssertTrue(cmd.contains("command -v bash"))
        XCTAssertTrue(cmd.contains("claude:%s"))
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
