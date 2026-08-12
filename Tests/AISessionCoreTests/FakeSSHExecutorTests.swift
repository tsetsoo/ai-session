import Foundation
import XCTest
@testable import AISessionCore

final class FakeSSHExecutorTests: XCTestCase {
    private let config = HostConnectionConfig(
        host: "host.test",
        port: 22,
        username: "user",
        privateKeyPEM: Data("test-key".utf8)
    )

    func testFakeReturnsCannedTmuxListOutput() async throws {
        let listOutput = "ai/claude/sigma-revenue\nai/codex/overnight\nrandom\n"
        let fake = FakeSSHExecutor(responsesByPrefix: [
            "tmux ls": SSHExecResult(exitCode: 0, stdout: listOutput, stderr: ""),
        ])

        let result = try await fake.exec(config, command: TmuxCommandBuilder.listSessions())

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, listOutput)
        XCTAssertEqual(result.stderr, "")
    }

    func testFakeCannedOutputParsesWithTmuxListParser() async throws {
        let listOutput = "ai/claude/sigma-revenue\nai/codex/overnight\nrandom\n"
        let fake = FakeSSHExecutor(responsesByPrefix: [
            "tmux ls": SSHExecResult(exitCode: 0, stdout: listOutput, stderr: ""),
        ])

        let result = try await fake.exec(config, command: TmuxCommandBuilder.listSessions())
        let parsed = TmuxListParser.parse(listSessionsOutput: result.stdout)

        XCTAssertEqual(parsed.ai.map(\.tmuxName), ["ai/claude/sigma-revenue", "ai/codex/overnight"])
        XCTAssertEqual(parsed.other.map(\.tmuxName), ["random"])
    }

    func testFakeThrowsCannedErrorByPrefix() async {
        let fake = FakeSSHExecutor(errorsByPrefix: [
            "command -v tmux": .tmuxMissing,
        ])

        do {
            _ = try await fake.exec(config, command: TmuxCommandBuilder.ensureTmuxInstalledCheck())
            XCTFail("Expected tmuxMissing")
        } catch let error as SSHRemoteError {
            XCTAssertEqual(error, .tmuxMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFakeReturnsDefaultWhenNoPrefixMatches() async throws {
        let fake = FakeSSHExecutor()

        let result = try await fake.exec(config, command: "unknown-command")

        XCTAssertEqual(result.exitCode, 127)
        XCTAssertEqual(result.stderr, "command not found")
    }

    func testRecordsEveryCommandInOrder() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "alpha": SSHExecResult(exitCode: 0, stdout: "a", stderr: ""),
            "beta": SSHExecResult(exitCode: 0, stdout: "b", stderr: "")
        ])
        let config = HostConnectionConfig(
            host: "example.com", port: 22, username: "tester", privateKeyPEM: Data()
        )

        _ = try await executor.exec(config, command: "alpha one")
        _ = try await executor.exec(config, command: "beta two")

        XCTAssertEqual(executor.recordedCommands, ["alpha one", "beta two"])
    }
}
