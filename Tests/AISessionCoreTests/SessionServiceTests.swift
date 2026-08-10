import XCTest
@testable import AISessionCore

final class SessionServiceTests: XCTestCase {
    private let config = HostConnectionConfig(
        host: "example.com",
        port: 22,
        username: "tester",
        privateKeyPEM: Data()
    )

    func testCreateAndListSession() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "command -v tmux": SSHExecResult(exitCode: 0, stdout: "/usr/bin/tmux\n", stderr: ""),
            "tmux ls": SSHExecResult(exitCode: 0, stdout: "", stderr: ""),
            "command -v 'claude'": SSHExecResult(exitCode: 0, stdout: "/usr/bin/claude\n", stderr: ""),
            "mkdir -p": SSHExecResult(exitCode: 0, stdout: "", stderr: ""),
            "tmux new-session": SSHExecResult(exitCode: 0, stdout: "", stderr: "")
        ])
        let service = SessionService(ssh: executor)

        let name = try await service.createSession(
            config: config,
            tool: .claude,
            slug: "demo",
            cwd: "/tmp/demo",
            title: "Demo"
        )
        XCTAssertEqual(name.tmuxName, "ai/claude/demo")

        let listed = try await service.listSessions(config: config)
        XCTAssertTrue(listed.ai.isEmpty)
        XCTAssertTrue(listed.other.isEmpty)
    }

    func testProbeTmuxThrowsWhenMissing() async {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "command -v tmux": SSHExecResult(exitCode: 127, stdout: "", stderr: "not found")
        ])

        do {
            try await SessionService(ssh: executor).probeTmux(config: config)
            XCTFail("Expected tmuxMissing")
        } catch let error as SSHRemoteError {
            XCTAssertEqual(error, .tmuxMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateThrowsWhenBinaryMissing() async {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux ls": SSHExecResult(exitCode: 0, stdout: "", stderr: ""),
            "command -v 'codex'": SSHExecResult(exitCode: 127, stdout: "", stderr: "not found")
        ])

        do {
            _ = try await SessionService(ssh: executor).createSession(
                config: config,
                tool: .codex,
                slug: "demo",
                cwd: "/tmp",
                title: nil
            )
            XCTFail("Expected binaryMissing")
        } catch let error as SSHRemoteError {
            XCTAssertEqual(error, .binaryMissing("codex"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateUsesUniqueSuffix() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux ls": SSHExecResult(exitCode: 0, stdout: "ai/claude/demo\n", stderr: ""),
            "command -v 'claude'": SSHExecResult(exitCode: 0, stdout: "/usr/bin/claude\n", stderr: ""),
            "mkdir -p": SSHExecResult(exitCode: 0, stdout: "", stderr: ""),
            "tmux new-session": SSHExecResult(exitCode: 0, stdout: "", stderr: "")
        ])

        let name = try await SessionService(ssh: executor).createSession(
            config: config,
            tool: .claude,
            slug: "demo",
            cwd: "/tmp",
            title: nil
        )
        XCTAssertEqual(name.tmuxName, "ai/claude/demo-2")
    }

    func testKillSessionExecutesSuccessfully() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux kill-session": SSHExecResult(exitCode: 0, stdout: "", stderr: "")
        ])

        try await SessionService(ssh: executor).killSession(
            config: config,
            tmuxName: "ai/claude/demo"
        )
    }
}
