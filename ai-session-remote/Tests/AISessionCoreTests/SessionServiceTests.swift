import XCTest
@testable import AISessionCore

final class SessionServiceTests: XCTestCase {
    func testRemoteErrorMessagesAreActionableAndConsistent() {
        XCTAssertEqual(
            SSHRemoteError.unreachable.userMessage,
            "Couldn't reach the computer. Check that it's on and connected to Tailscale, then try again."
        )
        XCTAssertEqual(
            ComputerErrorText.message(for: SSHRemoteError.authenticationFailed, computer: "mac-studio"),
            "The key on this device wasn't accepted by mac-studio. Check the user name and key in Access & keys."
        )
        XCTAssertEqual(
            ComputerErrorText.message(for: SSHRemoteError.binaryMissing("codex"), computer: "mac-studio"),
            "codex isn't installed on mac-studio. Install it there, then try again."
        )
        XCTAssertEqual(
            SSHRemoteError.commandFailed(exitCode: 23, stderr: "").userMessage,
            "Something went wrong on the computer (exit code 23). Try again in a moment."
        )
        XCTAssertEqual(
            ComputerErrorText.message(for: SSHRemoteError.commandFailed(exitCode: 1, stderr: "duplicate session: ai-x\n"),
                                      computer: "mac-studio"),
            "Something went wrong on mac-studio: duplicate session: ai-x"
        )
    }

    func testAMissingKeyInTheKeychainIsAnAccessProblem() {
        for error: Error in [KeychainPrivateKeyStoreError.itemNotFound, KeychainPrivateKeyStoreError.loadFailed(-25300)] {
            XCTAssertEqual(ComputerErrorText.message(for: error, computer: "mac-studio"),
                           "This device has no key for mac-studio. Add it in Access & keys.")
            XCTAssertTrue(ComputerErrorText.isAccessProblem(error))
        }
        XCTAssertTrue(ComputerErrorText.isAccessProblem(SSHRemoteError.authenticationFailed))
        XCTAssertFalse(ComputerErrorText.isAccessProblem(SSHRemoteError.unreachable))
    }

    func testAWordedErrorKeepsItsOwnText() {
        XCTAssertEqual(
            ComputerErrorText.message(for: SessionServiceError.invalidSlug("Bad Name"), computer: "mac-studio"),
            SessionServiceError.invalidSlug("Bad Name").errorDescription
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
            "tmux ls": mergedListResult(sessions: "", statuses: ""),
            "exec tmux new-session": SSHExecResult(exitCode: 0, stdout: "", stderr: "")
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
            "tmux ls": mergedListResult(sessions: "", statuses: ""),
            "exec tmux new-session": SSHExecResult(exitCode: 90, stdout: "", stderr: "")
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
            "tmux ls": mergedListResult(sessions: "ai/claude/demo", statuses: ""),
            "exec tmux new-session": SSHExecResult(exitCode: 0, stdout: "", stderr: "")
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

    private func mergedListResult(sessions: String, statuses: String) -> SSHExecResult {
        SSHExecResult(
            exitCode: 0,
            stdout: "\(sessions)\n\(RemoteScriptOutput.statusMarker)\n\(statuses)",
            stderr: ""
        )
    }

    func testListSessionsIssuesExactlyOneExec() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux ls": mergedListResult(sessions: "ai/claude/demo\t1700000000\t0", statuses: "")
        ])
        let service = SessionService(ssh: executor)

        let listed = try await service.listSessions(config: config)

        XCTAssertEqual(executor.recordedCommands.count, 1)
        XCTAssertEqual(listed.ai.map(\.tmuxName), ["ai/claude/demo"])
    }

    func testListSessionsAppliesAgentStatusesFromMergedOutput() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux ls": mergedListResult(
                sessions: "ai/claude/demo\t1700000000\t0",
                statuses: "---ai__claude__demo.json---\n{\"status\":\"busy\"}"
            )
        ])
        let service = SessionService(ssh: executor)

        let listed = try await service.listSessions(config: config)

        XCTAssertEqual(listed.ai.first?.status, .busy)
    }

    /// `~` must reach the host unquoted as `$HOME`: inside single quotes tmux gets a literal
    /// `~/programming`, can't enter it, and silently starts the session in `$HOME`.
    func testCreateSessionSendsTildeCwdForTheHostToExpand() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux ls": mergedListResult(sessions: "", statuses: ""),
            "exec tmux new-session": SSHExecResult(exitCode: 0, stdout: "", stderr: "")
        ])
        let service = SessionService(ssh: executor)

        _ = try await service.createSession(
            config: config, tool: .claude, slug: "demo", cwd: "~/my projects", title: nil
        )

        let create = try XCTUnwrap(executor.recordedCommands.last)
        XCTAssertTrue(create.contains("-c \"$HOME\"/'my projects' --"), create)
        XCTAssertFalse(create.contains("'~/"), create)
    }

    func testCreateSessionIssuesTwoExecsOnHappyPath() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux ls": mergedListResult(sessions: "", statuses: ""),
            "exec tmux new-session": SSHExecResult(exitCode: 0, stdout: "", stderr: "")
        ])
        let service = SessionService(ssh: executor)

        let name = try await service.createSession(
            config: config, tool: .claude, slug: "demo", cwd: "/tmp/demo", title: "Demo"
        )

        XCTAssertEqual(name.tmuxName, "ai/claude/demo")
        XCTAssertEqual(executor.recordedCommands.count, 2)
    }

    func testCreateSessionMapsExitNinetyToBinaryMissing() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux ls": mergedListResult(sessions: "", statuses: ""),
            "exec tmux new-session": SSHExecResult(exitCode: 90, stdout: "", stderr: "")
        ])
        let service = SessionService(ssh: executor)

        do {
            _ = try await service.createSession(
                config: config, tool: .claude, slug: "demo", cwd: "/tmp", title: nil
            )
            XCTFail("expected binaryMissing")
        } catch let error as SSHRemoteError {
            XCTAssertEqual(error, .binaryMissing("claude"))
        }
    }

    func testCreateSessionRetriesOnceOnDuplicateThenSucceeds() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux ls": mergedListResult(sessions: "", statuses: "")
        ])
        executor.enqueueResponses(
            [
                SSHExecResult(exitCode: 1, stdout: "", stderr: "duplicate session: ai/claude/demo"),
                SSHExecResult(exitCode: 0, stdout: "", stderr: "")
            ],
            forPrefix: "exec tmux new-session"
        )
        let service = SessionService(ssh: executor)

        let name = try await service.createSession(
            config: config, tool: .claude, slug: "demo", cwd: "/tmp/demo", title: "Demo"
        )

        XCTAssertEqual(name.tmuxName, "ai/claude/demo")
        // 2 execs per attempt (list + create) across the duplicate-then-succeed pair of attempts.
        XCTAssertEqual(executor.recordedCommands.count, 4)
    }

    func testPromoteSessionIssuesExactlyOneExec() async throws {
        let executor = FakeSSHExecutor(responsesByPrefix: [
            "tmux rename-session": SSHExecResult(exitCode: 0, stdout: "", stderr: "")
        ])
        let service = SessionService(ssh: executor)

        try await service.promoteSession(
            config: config,
            fromTmuxName: "old",
            to: try XCTUnwrap(SessionName(tool: .claude, slug: "demo"))
        )

        XCTAssertEqual(executor.recordedCommands.count, 1)
    }
}
