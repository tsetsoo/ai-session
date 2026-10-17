import AISessionCore
import XCTest
@testable import AISessionRemote

@MainActor
final class AppModelTests: XCTestCase {
    private struct ListingFailed: Error {}

    private static let listedAt = ISO8601DateFormatter().date(from: "2026-10-18T00:00:00Z")!
    private let mac = DemoFixtures.macStudio
    private let linux = DemoFixtures.linuxBox

    private func makeModel(listTmux: @escaping (Computer) async throws -> Set<String> = { _ in [] }) -> AppModel {
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-\(UUID().uuidString).json"))
        // After the fixtures were created, whatever the wall clock says.
        let model = AppModel(store: TodoHubStore(cache: cache), demo: false, listTmux: listTmux,
                             now: { Self.listedAt })
        model.store.seedForDemo(
            todos: DemoFixtures.todos, conversations: DemoFixtures.conversations,
            sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
        )
        return model
    }

    func testDemoModelUsesAScratchCacheNotTheRealOne() {
        let model = AppModel(demo: true)
        XCTAssertNotEqual(model.store.cacheFileURL, TodoHubCache.applicationSupport().fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.store.cacheFileURL.path))
        XCTAssertEqual(model.store.todos, DemoFixtures.todos)
    }

    func testDemoModelNeverBuildsAHubClient() async {
        var built = 0
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-demo-\(UUID().uuidString).json"))
        let store = TodoHubStore(cache: cache, makeClient: {
            built += 1
            return TodoHubClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "real-token")
        })
        let model = AppModel(store: store, demo: true)
        let todo = DemoFixtures.todos[0]
        let conversation = DemoFixtures.conversations[0]
        await store.refresh()
        await model.openFromNotification("not-a-demo-todo")
        store.startLiveUpdates()
        store.stopLiveUpdates()
        await store.toggle(todo)
        await store.delete(todo)
        await store.createTodo(section: .sp, title: "Quick add")
        await store.setProject("p1", for: todo)
        _ = try? await store.openConversation(for: todo)
        try? await store.closeConversation(conversation, config: DemoFixtures.config)
        try? await store.deleteConversation(conversation, config: DemoFixtures.config)
        _ = try? await store.sessions(projectId: "p1")
        _ = try? await store.memories(projectId: "p1")
        _ = try? await store.weekly(projectId: nil, weekStart: nil)
        XCTAssertEqual(built, 0)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path))
        XCTAssertEqual(store.todos, DemoFixtures.todos)
    }

    func testBoardReflectsStoreChanges() {
        let model = makeModel()
        XCTAssertEqual(model.board.needsYou.count, 2)
        model.store.seedForDemo(todos: [], conversations: [], sectionComputers: [], computers: [])
        XCTAssertTrue(model.board.needsYou.isEmpty)
    }

    func testNotificationTapForAKnownTodoOpensIt() async {
        let model = makeModel()
        let todo = DemoFixtures.todos[0]
        await model.openFromNotification(todo.id)
        XCTAssertEqual(model.pendingOpenTodoID, todo.id)
    }

    func testRefreshLivenessLeavesFailingComputerAbsent() async {
        let mac = mac
        let model = makeModel { computer in
            if computer.id == mac.id { return ["todo-t1"] }
            throw ListingFailed()
        }
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.liveTmux[mac.id], ["todo-t1"])
        XCTAssertNil(model.liveTmux[linux.id])
    }

    func testBoardUsesLiveTmuxToDemoteDeadConversations() async {
        let model = makeModel { _ in [] }   // both computers reachable, no live sessions
        await model.refreshLiveness(hosts: [])
        XCTAssertTrue(model.board.needsYou.isEmpty)
        XCTAssertTrue(model.board.runningNow.isEmpty)
    }

    /// Lets the model's observation of the board catch up.
    private func settle(_ model: AppModel, until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    private actor Listing {
        var names: Set<String> = []
        func set(_ names: Set<String>) { self.names = names }
    }

    func testConversationStartedAfterTheListingRunsAndListsAgain() async {
        let listing = Listing()
        let model = makeModel { _ in await listing.names }
        await model.refreshLiveness(hosts: [])
        XCTAssertTrue(model.board.runningNow.isEmpty)   // the fixtures' sessions aren't listed
        let requestsBefore = model.relistRequests

        // Started after that listing: the hub says busy, the listing can't know it yet.
        let started = Conversation(
            todoId: "t7", computer: mac, cwd: "~/notes", tool: "claude", tmuxName: "todo-t7",
            sessionId: "s7", status: .busy,
            createdAt: "2026-10-18T00:00:05Z"
        )
        model.store.seedForDemo(
            todos: DemoFixtures.todos, conversations: DemoFixtures.conversations + [started],
            sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
        )
        XCTAssertEqual(model.board.status(forTodo: "t7"), .working)
        XCTAssertEqual(model.board.runningNow.map(\.todoId), ["t7"])
        XCTAssertEqual(model.board.conversation(atShortcut: 1)?.todoId, "t7")
        await settle(model) { model.relistRequests != requestsBefore }
        XCTAssertEqual(model.relistRequests, requestsBefore + 1)

        // Listed again: it's there, and nothing more is asked.
        await listing.set(["todo-t7"])
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.board.status(forTodo: "t7"), .working)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.relistRequests, requestsBefore + 1)
    }

    func testOlderConversationMissingFromAListingIsClosedWithoutListingAgain() async {
        let model = makeModel { _ in [] }
        await model.refreshLiveness(hosts: [])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.board.status(forTodo: "t1"), .closed)
        XCTAssertEqual(model.relistRequests, 0)
    }

    private actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        var waiting: Int { continuations.count }
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func open() { opened = true; continuations.forEach { $0.resume() }; continuations = [] }
    }

    private actor Mode {
        var slow = false
        func set(slow: Bool) { self.slow = slow }
    }

    func testStaleRefreshDoesNotOverwriteNewerResult() async {
        let gate = Gate()
        let mode = Mode()
        await mode.set(slow: true)
        let model = makeModel { _ in
            if await mode.slow {
                await gate.wait()
                return ["old"]
            }
            return ["new"]
        }
        let first = Task { await model.refreshLiveness(hosts: []) }
        while await gate.waiting == 0 { await Task.yield() }   // call 1 is parked in its listing
        await mode.set(slow: false)
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.liveTmux[mac.id], ["new"])
        await gate.open()
        await first.value
        XCTAssertEqual(model.liveTmux[mac.id], ["new"])
    }

    func testCancelledRefreshKeepsPreviousResult() async {
        let gate = Gate()
        let mode = Mode()
        let model = makeModel { _ in
            if await mode.slow {
                await gate.wait()
                return []
            }
            return ["known"]
        }
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.liveTmux[mac.id], ["known"])
        await mode.set(slow: true)
        let task = Task { await model.refreshLiveness(hosts: []) }
        while await gate.waiting == 0 { await Task.yield() }
        task.cancel()
        await gate.open()
        await task.value
        XCTAssertEqual(model.liveTmux[mac.id], ["known"])
    }
}
