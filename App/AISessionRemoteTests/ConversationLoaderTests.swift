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

    private func loader(
        open: @escaping () async throws -> Conversation,
        cached: Conversation? = nil,
        offline: Bool = false,
        resolve: (() throws -> Void)? = nil,
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
            }
        )
        return (ConversationLoader(todo: todo(), dependencies: deps), calls)
    }

    private func readyLoader() async -> ConversationLoader {
        let conv = conversation()
        let (l, _) = loader(open: { conv })
        await l.start()
        return l
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
        let (l, _) = loader(open: { throw TodoHubError.unauthorized })
        await l.start()
        XCTAssertEqual(l.phase, .problem(.hub(TodoHubStore.message(for: TodoHubError.unauthorized))))
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
        await l.attachIfRunning(nil)
        XCTAssertEqual(l.phase, .idle)
        await l.attachIfRunning(conversation(status: .closed))
        XCTAssertEqual(l.phase, .idle)
        XCTAssertEqual(calls.open, 0)
        XCTAssertEqual(calls.resolve, 0)
        await l.attachIfRunning(conversation(status: .busy))
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

    func testStartWhilePreparingIsNoOp() async {
        let conv = conversation()
        let (l, calls) = loader(open: {
            try await Task.sleep(nanoseconds: 100_000_000)
            return conv
        })
        async let first: Void = l.start()
        await Task.yield()
        XCTAssertEqual(l.phase, .preparing)
        await l.start()
        await first
        XCTAssertEqual(calls.open, 1)
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

    func testConnectionFailedIsUnreachable() async {
        let l = await readyLoader()
        l.connectionFailed()
        XCTAssertEqual(l.phase, .problem(.unreachable("Mac Studio")))
    }

    func testConnectionFailedIgnoredWhenNotReady() {
        let (l, _) = loader(open: { self.conversation() })
        l.connectionFailed()
        XCTAssertEqual(l.phase, .idle)
    }

    func testResetAfterCloseReturnsToIdleAndCanStartAgain() async {
        let l = await readyLoader()
        l.reset()
        XCTAssertEqual(l.phase, .idle)
        await l.start()
        guard case .ready = l.phase else { return XCTFail("\(l.phase)") }
    }
}
