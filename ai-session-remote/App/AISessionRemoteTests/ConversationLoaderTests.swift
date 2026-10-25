import AISessionCore
import XCTest
@testable import AISessionRemote

@MainActor
final class ConversationLoaderTests: XCTestCase {
    private let computer = Computer(id: "c1", name: "Mac Studio", hostname: "studio", username: "me")
    private let hostID = UUID()

    private func todo() -> Todo { Todo(id: "t1", section: .sp, title: "Fix it") }

    private func conversation(status: ConversationStatus = .idle) -> Conversation {
        Conversation(todoId: "t1", computer: computer, cwd: "~/proj", tool: "claude",
                     tmuxName: "todo-t1", sessionId: "s1", status: status)
    }

    private final class Calls { var open = 0; var resolve = 0 }

    /// Holds `openConversation` until the test opens it, and tells the test when it got there.
    @MainActor
    private final class Gate {
        private var reached = false
        private var reachedWaiter: CheckedContinuation<Void, Never>?
        private var passWaiter: CheckedContinuation<Void, Never>?

        func pass() async {
            reached = true
            reachedWaiter?.resume()
            reachedWaiter = nil
            await withCheckedContinuation { passWaiter = $0 }
        }

        func untilReached() async {
            guard !reached else { return }
            await withCheckedContinuation { reachedWaiter = $0 }
        }

        func open() {
            passWaiter?.resume()
            passWaiter = nil
        }
    }

    private func loader(
        open: @escaping () async throws -> Conversation,
        cached: Conversation? = nil,
        offline: Bool = false,
        resolve: (() throws -> Void)? = nil,
        servers: [String]? = nil,
        unsupported: @escaping (Computer) -> Void = { _ in },
        calls: Calls = Calls()
    ) -> (ConversationLoader, Calls) {
        let config = HostConnectionConfig(host: "studio", port: 22, username: "me", privateKeyPEM: Data())
        let hostID = hostID
        let deps = ConversationLoader.Dependencies(
            openConversation: { _ in calls.open += 1; return try await open() },
            cachedConversation: { _ in cached },
            isOffline: { offline },
            resolveConfig: { _ in
                calls.resolve += 1
                try resolve?()
                return (hostID, config)
            },
            launchServers: { _ in servers },
            serversUnsupported: unsupported
        )
        return (ConversationLoader(todo: todo(), dependencies: deps), calls)
    }

    private func readyLoader() async -> ConversationLoader {
        let conv = conversation()
        let (l, _) = loader(open: { conv })
        await l.start()
        return l
    }

    func testAnotherConversationIsADifferentTerminal() {
        let config = HostConnectionConfig(host: "studio", port: 22, username: "me", privateKeyPEM: Data())
        let quiet = Conversation(
            id: "quiet", todoId: "t1", computer: computer, cwd: "~/proj", tool: "claude",
            tmuxName: "ai/claude/todo-t1", sessionId: "s-quiet", status: .idle
        )
        let waiting = Conversation(
            id: "wait", todoId: "t1", computer: computer, cwd: "~/proj", tool: "claude",
            tmuxName: "ai/claude/todo-t1-wait", sessionId: "s-wait", status: .waiting
        )
        let attached = OpenTodoConversation(conversation: quiet, hostID: hostID, config: config, title: "Fix it")
        let needed = OpenTodoConversation(conversation: waiting, hostID: hostID, config: config, title: "Fix it")
        XCTAssertNotEqual(attached.id, needed.id)
        XCTAssertNotEqual(attached, needed)
    }

    func testShowAttachesTheSelectedConversation() async {
        let quiet = Conversation(
            id: "quiet", todoId: "t1", computer: computer, cwd: "~/proj", tool: "claude",
            tmuxName: "ai/claude/todo-t1", sessionId: "s-quiet", status: .idle
        )
        let waiting = Conversation(
            id: "wait", todoId: "t1", computer: computer, cwd: "~/proj", tool: "claude",
            tmuxName: "ai/claude/todo-t1-wait", sessionId: "s-wait", status: .waiting
        )
        let (l, _) = loader(open: { quiet })
        await l.start()
        l.show(waiting)
        guard case let .ready(open) = l.phase else { return XCTFail("\(l.phase)") }
        XCTAssertEqual(open.conversation.tmuxName, "ai/claude/todo-t1-wait")
        XCTAssertEqual(open.id, "wait")
    }

    func testStartSuccessIsReady() async {
        let conv = conversation()
        let (l, calls) = loader(open: { conv })
        XCTAssertEqual(l.phase, .idle)
        await l.start()
        guard case let .ready(open) = l.phase else { return XCTFail("\(l.phase)") }
        XCTAssertEqual(open.conversation, conv)
        XCTAssertEqual(open.hostID, hostID)
        XCTAssertEqual(open.title, "Fix it")
        XCTAssertEqual(calls.open, 1)
    }

    func testNoComputerConflictMapsToNoComputer() async {
        let (l, _) = loader(open: { throw TodoHubError.conflict("no computer for section Sp") })
        await l.start()
        XCTAssertEqual(l.phase, .problem(.noComputer(.sp)))
    }

    func testOtherHubErrorMapsToHub() async {
        let error = TodoHubError.server(status: 500, message: "boom")
        let (l, _) = loader(open: { throw error })
        await l.start()
        XCTAssertEqual(l.phase, .problem(.hub(TodoHubStore.message(for: error))))
    }

    func testRejectedTokenIsTokenRejected() async {
        let (l, _) = loader(open: { throw TodoHubError.unauthorized })
        await l.start()
        XCTAssertEqual(l.phase, .problem(.tokenRejected))
    }

    func testMissingHostIsNeedsAccess() async {
        let c = computer
        let (l, _) = loader(open: { self.conversation() }, resolve: { throw HostLookup.Failure.noHost(c) })
        await l.start()
        XCTAssertEqual(l.phase, .problem(.needsAccess(computer)))
    }

    func testKeyUnavailableIsKeyMissing() async {
        let (l, _) = loader(open: { self.conversation() }, resolve: { throw HostLookup.Failure.keyUnavailable("Studio") })
        await l.start()
        XCTAssertEqual(l.phase, .problem(.keyMissing("Studio")))
    }

    func testOfflineUsesCachedConversation() async {
        let conv = conversation()
        let (l, calls) = loader(open: { XCTFail("hub called"); return conv }, cached: conv, offline: true)
        await l.start()
        guard case .ready = l.phase else { return XCTFail("\(l.phase)") }
        XCTAssertEqual(calls.open, 0)
    }

    func testSelectionDoesNotStartConversation() async {
        let (l, calls) = loader(open: { self.conversation() })
        l.attachIfRunning(nil)
        XCTAssertEqual(l.phase, .idle)
        l.attachIfRunning(conversation(status: .closed))
        XCTAssertEqual(l.phase, .idle)
        XCTAssertEqual(calls.open, 0)
        XCTAssertEqual(calls.resolve, 0)
        l.attachIfRunning(conversation(status: .busy))
        guard case .ready = l.phase else { return XCTFail("\(l.phase)") }
        XCTAssertEqual(calls.open, 0)
    }

    func testExit127IsHelpersMissing() async {
        let l = await readyLoader()
        l.ended(exitStatus: 127)
        XCTAssertEqual(l.phase, .problem(.helpersMissing("Mac Studio")))
    }

    func testFolderMissingCarriesCwd() async {
        let l = await readyLoader()
        l.ended(exitStatus: 93)
        XCTAssertEqual(l.phase, .problem(.folderMissing("Mac Studio", "~/proj")))
    }

    func testExitNilStaysReady() async {
        let l = await readyLoader()
        l.ended(exitStatus: nil)
        guard case .ready = l.phase else { return XCTFail("\(l.phase)") }
    }

    func testOldScriptsRetryWithoutServers() async throws {
        let conv = conversation()
        var unsupported: [String] = []
        let (l, _) = loader(open: { conv }, servers: ["grafana", "slack"], unsupported: { unsupported.append($0.id) })
        await l.start()
        guard case let .ready(first) = l.phase else { return XCTFail("\(l.phase)") }
        XCTAssertTrue(first.attachCommand.contains("--mcp"))

        // Scripts from before MCP support reject `--mcp` at once: the same attach, without it.
        l.ended(exitStatus: 64)
        guard case let .ready(retry) = l.phase else { return XCTFail("\(l.phase)") }
        XCTAssertNil(retry.mcpServers)
        XCTAssertFalse(retry.attachCommand.contains("--mcp"))
        XCTAssertNotEqual(retry.surfaceID, first.surfaceID, "the terminal reconnects with the new command")
        XCTAssertNotEqual(retry, first, "a phase equal to the last would not notify")
        XCTAssertEqual(unsupported, ["c1"])

        // A second 64 is the tool's own: the usual ended card, no further retry.
        l.ended(exitStatus: 64)
        guard case let .ready(after) = l.phase else { return XCTFail("\(l.phase)") }
        XCTAssertEqual(after.surfaceID, retry.surfaceID)
        XCTAssertEqual(unsupported, ["c1"])
    }

    func testLateExit64IsNotARetry() async {
        var now = Date()
        let conv = conversation()
        let config = HostConnectionConfig(host: "studio", port: 22, username: "me", privateKeyPEM: Data())
        let hostID = hostID
        let deps = ConversationLoader.Dependencies(
            openConversation: { _ in conv },
            cachedConversation: { _ in nil },
            isOffline: { false },
            resolveConfig: { _ in (hostID, config) },
            launchServers: { _ in ["grafana"] },
            now: { now }
        )
        let l = ConversationLoader(todo: todo(), dependencies: deps)
        await l.start()
        guard case let .ready(first) = l.phase else { return XCTFail("\(l.phase)") }
        now += 60
        l.ended(exitStatus: 64)
        guard case let .ready(after) = l.phase else { return XCTFail("\(l.phase)") }
        XCTAssertEqual(after.surfaceID, first.surfaceID)
        XCTAssertEqual(after.mcpServers, ["grafana"])
    }

    func testRestartAttachesAfresh() async {
        let l = await readyLoader()
        guard case let .ready(first) = l.phase else { return XCTFail("\(l.phase)") }
        l.restart(first.conversation)
        guard case let .ready(again) = l.phase else { return XCTFail("\(l.phase)") }
        XCTAssertNotEqual(again.surfaceID, first.surfaceID)
    }

    func testStartWhilePreparingIsNoOp() async {
        let conv = conversation()
        let gate = Gate()
        let (l, calls) = loader(open: {
            await gate.pass()
            return conv
        })
        let first = Task { await l.start() }
        // The first start is inside openConversation: deterministically `.preparing`.
        await gate.untilReached()
        XCTAssertEqual(l.phase, .preparing)
        await l.start()
        XCTAssertEqual(calls.open, 1)
        gate.open()
        await first.value
        XCTAssertEqual(calls.open, 1)
        guard case .ready = l.phase else { return XCTFail("\(l.phase)") }
    }

    func testStartFromProblemRetries() async {
        let conv = conversation()
        var fail = true
        let (l, calls) = loader(open: {
            if fail { throw TodoHubError.unauthorized }
            return conv
        })
        await l.start()
        fail = false
        await l.start()
        guard case .ready = l.phase else { return XCTFail("\(l.phase)") }
        XCTAssertEqual(calls.open, 2)
    }

    func testConnectionFailureCards() async {
        let cases: [(TerminalConnectFailure, FrameProblem)] = [
            (.unreachable, .unreachable("Mac Studio")),
            (.signIn, .signInFailed("Mac Studio")),
            (.hostKeyChanged, .hostKeyChanged("Mac Studio")),
            (.terminal, .terminalFailed("Mac Studio")),
        ]
        for (failure, problem) in cases {
            let l = await readyLoader()
            l.connectionFailed(failure)
            XCTAssertEqual(l.phase, .problem(problem))
        }
    }

    func testConnectionFailedIgnoredWhenNotReady() {
        let (l, _) = loader(open: { self.conversation() })
        l.connectionFailed(.unreachable)
        XCTAssertEqual(l.phase, .idle)
    }

    func testClassifyConnectErrors() {
        typealias F = TerminalConnectFailure
        // Can't reach the computer: whatever an earlier handshake noted.
        XCTAssertEqual(F.classify(SSHRemoteError.unreachable, signInProblem: nil), .unreachable)
        XCTAssertEqual(F.classify(SSHRemoteError.unreachable, signInProblem: .hostKeyChanged), .unreachable)
        XCTAssertEqual(F.classify(SSHTerminalSessionError.connectionFailed, signInProblem: nil), .unreachable)
        // Sign-in: a rejected or unreadable key.
        XCTAssertEqual(F.classify(SSHRemoteError.authenticationFailed, signInProblem: nil), .signIn)
        XCTAssertEqual(F.classify(SSHTerminalSessionError.invalidPrivateKey, signInProblem: nil), .signIn)
        XCTAssertEqual(F.classify(SSHTerminalSessionError.channelSetupFailed, signInProblem: .keyRejected), .signIn)
        // The host's identity changed: the handshake noted it, whatever the channel said.
        XCTAssertEqual(F.classify(SSHRemoteError.authenticationFailed, signInProblem: .hostKeyChanged), .hostKeyChanged)
        XCTAssertEqual(F.classify(SSHTerminalSessionError.channelSetupFailed, signInProblem: .hostKeyChanged),
                       .hostKeyChanged)
        XCTAssertEqual(
            F.classify(SSHChannelOpenFailure(underlying: SSHRemoteError.authenticationFailed), signInProblem: nil),
            .signIn
        )
        // Signed in but no terminal.
        XCTAssertEqual(F.classify(SSHTerminalSessionError.channelSetupFailed, signInProblem: nil), .terminal)
    }

    func testSignInRecordFollowsTheNewestHandshake() {
        let host = "record-\(UUID().uuidString)"
        XCTAssertNil(SSHSignInRecord.problem(hostID: host))
        SSHSignInRecord.hostKeyChecked(hostID: host, matched: false)
        XCTAssertEqual(SSHSignInRecord.problem(hostID: host), .hostKeyChanged)
        // Forgetting the host's key (Settings) clears it.
        TOFUHostKeyStore(defaults: UserDefaults(suiteName: host)!).forget(hostID: host)
        XCTAssertNil(SSHSignInRecord.problem(hostID: host))
        SSHSignInRecord.hostKeyChecked(hostID: host, matched: true)
        SSHSignInRecord.keyRejected(hostID: host)
        XCTAssertEqual(SSHSignInRecord.problem(hostID: host), .keyRejected)
        // A new handshake starts with the host's identity: an earlier rejection is stale.
        SSHSignInRecord.hostKeyChecked(hostID: host, matched: true)
        XCTAssertNil(SSHSignInRecord.problem(hostID: host))
    }

    func testResetAfterCloseReturnsToIdleAndCanStartAgain() async {
        let l = await readyLoader()
        l.reset()
        XCTAssertEqual(l.phase, .idle)
        await l.start()
        guard case .ready = l.phase else { return XCTFail("\(l.phase)") }
    }
}
