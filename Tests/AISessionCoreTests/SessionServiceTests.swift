import XCTest
@testable import AISessionCore

final class SessionServiceTests: XCTestCase {
    func testRemoteErrorMessagesAreActionableAndConsistent() {
        XCTAssertEqual(
            SSHRemoteError.unreachable.userMessage,
            "Could not reach the host. Check Tailscale and network, then try again."
        )
        XCTAssertEqual(
            SSHRemoteError.authenticationFailed.userMessage,
            "SSH authentication failed. Verify the username and private key, or the host's key may have changed — check with \"Forget Host Key\" in the host editor."
        )
        XCTAssertEqual(
            SSHRemoteError.tmuxMissing.userMessage,
            "tmux was not found on this host's SSH PATH. Install it (`brew install tmux` / `apt install tmux`) or ensure it is available at /opt/homebrew/bin or /usr/local/bin."
        )
        XCTAssertEqual(
            SSHRemoteError.binaryMissing("codex").userMessage,
            "The required binary 'codex' was not found on this host. Install it and ensure it is on PATH."
        )
        XCTAssertEqual(
            SSHRemoteError.commandFailed(exitCode: 23, stderr: "").userMessage,
            "The remote command failed (exit code 23)."
        )
        XCTAssertEqual(
            SSHRemoteError.commandFailed(exitCode: 1, stderr: "permission denied\n").userMessage,
            "permission denied"
        )
    }

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

    func testListSessionsTreatsMissingSocketAsEmpty() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux ls": SSHExecResult(
                exitCode: 1,
                stdout: "",
                stderr: "error connecting to /tmp/tmux-1000/default (No such file or directory)\n"
            )
        ])

        let listed = try await SessionService(ssh: executor).listSessions(config: config)
        XCTAssertTrue(listed.ai.isEmpty)
        XCTAssertTrue(listed.other.isEmpty)
    }

    func testProbeBinariesParsesPathsAndMissing() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "printf 'tmux:%s": SSHExecResult(
                exitCode: 0,
                stdout: "tmux:/usr/bin/tmux\nclaude:MISSING\ncodex:/usr/bin/codex\nagent:MISSING\nbash:/bin/bash\n",
                stderr: ""
            )
        ])
        let health = try await SessionService(ssh: executor).probeBinaries(config: config)
        XCTAssertEqual(health.tmux, "/usr/bin/tmux")
        XCTAssertNil(health.claude)
        XCTAssertEqual(health.codex, "/usr/bin/codex")
        XCTAssertNil(health.agent)
        XCTAssertEqual(health.shell, "/bin/bash")
    }

    func testPromoteRenamesAndWritesMetadata() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux rename-session -t 'random' 'ai/claude/demo'":
                SSHExecResult(exitCode: 0, stdout: "", stderr: ""),
            "mkdir -p ~/.ai-remote/sessions":
                SSHExecResult(exitCode: 0, stdout: "", stderr: "")
        ])
        let target = try XCTUnwrap(SessionName(tool: .claude, slug: "demo"))
        try await SessionService(ssh: executor).promoteSession(
            config: config, fromTmuxName: "random", to: target
        )
    }
}
