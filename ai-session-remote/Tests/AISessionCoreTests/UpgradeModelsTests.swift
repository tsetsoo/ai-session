@testable import AISessionCore
import XCTest

/// Updating an agent CLI from the Health page: the exact host command and what comes back.
final class UpgradeModelsTests: XCTestCase {
    func testCommand() {
        let command = TmuxCommandBuilder.upgradeTool("cursor")
        XCTAssertTrue(command.hasSuffix(#""$HOME/.ai-remote/bin/ai-todo-status" upgrade 'cursor'"#), command)
    }

    func testUpdatedSummary() throws {
        let result = try UpgradeResult.decode(Data(#"""
        {"tool":"cursor","method":"native","before":"2026.10.14-aaa","after":"2026.10.19-bbb","result":"updated",
         "message":"Updated","command":"~/.local/bin/agent update"}
        """#.utf8))
        XCTAssertFalse(result.isFailed)
        XCTAssertEqual(result.summary, "Cursor updated to 2026.10.19-bbb (was 2026.10.14-aaa). Running conversations keep the old version until they're restarted.")
    }

    func testCodexUpdatedNamesItsServer() throws {
        let result = try UpgradeResult.decode(Data(#"{"tool":"codex","result":"updated","before":"0.166.0","after":"0.167.0","daemon":"0.167.0"}"#.utf8))
        XCTAssertEqual(result.summary, "Codex updated to 0.167.0 (was 0.166.0). Its shared server runs 0.167.0. Running conversations keep the old version until they're restarted.")
    }

    func testCodexServerVersionAndCurrent() throws {
        let result = try UpgradeResult.decode(Data(#"{"tool":"codex","result":"current","before":"0.167.0","after":"0.167.0","daemon":"0.167.0","method":"managed","message":null,"command":null}"#.utf8))
        XCTAssertEqual(result.daemon, "0.167.0")
        XCTAssertEqual(result.summary, "Codex is already the latest version (0.167.0).")
    }

    func testUnsupportedShowsTheCommand() throws {
        let npm = try UpgradeResult.decode(Data(#"{"tool":"claude","result":"unsupported","method":"npm","command":"npm install -g @anthropic-ai/claude-code@latest"}"#.utf8))
        XCTAssertEqual(npm.summary, "Claude isn't updated from here. Run this on the computer: npm install -g @anthropic-ai/claude-code@latest")
        let app = try UpgradeResult.decode(Data(#"{"tool":"codex","result":"unsupported","method":"app","command":null}"#.utf8))
        XCTAssertEqual(app.summary, "Codex comes with an app; update that app.")
    }

    func testFailedSaysWhy() throws {
        let failed = try UpgradeResult.decode(Data(#"{"tool":"claude","result":"failed","message":"network unreachable"}"#.utf8))
        XCTAssertTrue(failed.isFailed)
        XCTAssertEqual(failed.summary, "Claude wasn't updated: network unreachable")
        let silent = try UpgradeResult.decode(Data(#"{"tool":"claude","result":"failed","message":""}"#.utf8))
        XCTAssertEqual(silent.summary, "Claude wasn't updated: the update failed.")
    }

    func testDoctorUpdateField() throws {
        let health = try HostHealth.decode(Data(#"""
        {"doctor_version":4,"tools":{
          "claude":{"installed":true,"version":"2.1.319","method":"native","update":{"runs":true,"command":"~/.local/bin/claude update"}},
          "codex":{"installed":true,"version":"0.160.0","method":"homebrew","update":{"runs":false,"command":"brew upgrade --cask codex"}},
          "cursor":{"installed":true,"version":"2026.10.19","method":"native"}}}
        """#.utf8))
        XCTAssertEqual(health.tools?["claude"]?.update, HostHealth.Update(runs: true, command: "~/.local/bin/claude update"))
        XCTAssertEqual(health.tools?["codex"]?.update?.runs, false)
        XCTAssertNil(health.tools?["cursor"]?.update)  // older scripts: no button
    }
}
