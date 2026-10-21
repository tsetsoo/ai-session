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
        await store.createTodo(title: "Quick add", projectId: "p1")
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

    func testOpenTodoSelectsTheWaitingConversation() {
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("open-urgent-\(UUID().uuidString).json"))
        let store = TodoHubStore(cache: cache)
        func conv(_ id: String, _ status: ConversationStatus, updated: String) -> Conversation {
            Conversation(
                id: id, todoId: "t", computer: mac, cwd: "~/x", tool: "claude", tmuxName: "tmux-\(id)",
                sessionId: id, status: status, statusUpdatedAt: updated, createdAt: "2026-10-16T09:00:00Z"
            )
        }
        store.applyFetched(todos: [Todo(id: "t", section: .sp, title: "Keep going")], conversations: [
            conv("idle", .idle, updated: "2026-10-20T12:00:00Z"),
            conv("wait", .waiting, updated: "2026-10-20T08:00:00Z"),
        ])
        XCTAssertEqual(store.conversationToOpen(forTodo: "t"), "wait")
    }

    func testBoardReflectsStoreChanges() {
        let model = makeModel()
        XCTAssertEqual(model.board.needsYou.count, 2)
        model.store.seedForDemo(todos: [], conversations: [], sectionComputers: [], computers: [])
        XCTAssertTrue(model.board.needsYou.isEmpty)
    }

    func testOpenPaletteHoldsTerminalAutoFocus() {
        let model = makeModel()
        XCTAssertTrue(model.allowsTerminalAutoFocus)
        model.isPaletteOpen = true
        XCTAssertFalse(model.allowsTerminalAutoFocus)
        model.isPaletteOpen = false
        XCTAssertTrue(model.allowsTerminalAutoFocus)
    }

    func testEachTerminalFocusRequestIsNew() {
        // Asking twice for the same todo must still reach its frame (an onChange).
        let model = makeModel()
        XCTAssertNil(model.terminalFocusRequest)
        model.requestTerminalFocus(todoID: "t1")
        let first = model.terminalFocusRequest
        model.requestTerminalFocus(todoID: "t1")
        XCTAssertEqual(model.terminalFocusRequest?.todoID, "t1")
        XCTAssertNotEqual(model.terminalFocusRequest, first)
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
        var staleMac = false
        var failMac = false
        func set(slow: Bool) { self.slow = slow }
        func set(staleMac: Bool) { self.staleMac = staleMac }
        func set(failMac: Bool) { self.failMac = failMac }
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
        // Superseded by a refresh that answered: nothing to ask again.
        XCTAssertEqual(model.livenessAbandoned, 0)
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
        // The newest refresh gave no answer and none runs: waiting selections ask again.
        XCTAssertEqual(model.livenessAbandoned, 1)
    }

    func testBoardReadsReuseTheCachedInstance() {
        let model = makeModel()
        let first = model.board
        XCTAssertTrue(first === model.board)
        model.store.seedForDemo(todos: [], conversations: [], sectionComputers: [], computers: [])
        XCTAssertFalse(first === model.board)
        XCTAssertTrue(model.board.needsYou.isEmpty)
        XCTAssertTrue(model.board === model.board)
    }

    func testStaleRefreshListsOnlyTheStaleComputer() async {
        let calls = ListingCalls()
        let phase = ListingPhase()
        let mac = mac
        let linux = linux
        let model = makeModel { computer in
            await calls.record(computer.id)
            if computer.id == linux.id { return ["keep-linux"] }
            let listingMac = await phase.listingMac
            return listingMac ? ["todo-t7"] : ["mac-before"]
        }
        await model.refreshLiveness(hosts: [])
        _ = await calls.take()
        XCTAssertEqual(model.liveTmux[linux.id], ["keep-linux"])
        XCTAssertEqual(model.liveTmux[mac.id], ["mac-before"])

        let started = Conversation(
            todoId: "t7", computer: mac, cwd: "~/notes", tool: "claude", tmuxName: "todo-t7",
            sessionId: "s7", status: .busy, createdAt: "2026-10-18T00:00:05Z"
        )
        model.store.seedForDemo(
            todos: DemoFixtures.todos, conversations: DemoFixtures.conversations + [started],
            sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
        )
        await phase.setListingMac(true)
        await model.refreshLiveness(hosts: [], scope: .stale)
        let staleCalls = await calls.take()
        XCTAssertEqual(staleCalls, [mac.id])
        XCTAssertEqual(model.liveTmux[linux.id], ["keep-linux"], "a computer that was not stale stays listed")
        XCTAssertEqual(model.liveTmux[mac.id], ["todo-t7"])
        XCTAssertEqual(model.board.status(forTodo: "t7"), .working)
        XCTAssertTrue(model.board.newerThanListing.isEmpty)
        XCTAssertEqual(model.livenessAbandoned, 0)

        // Nothing is stale anymore: no listing, and the generation is not bumped (abandoned stays).
        await model.refreshLiveness(hosts: [], scope: .stale)
        let idleCalls = await calls.take()
        XCTAssertTrue(idleCalls.isEmpty)
        XCTAssertEqual(model.liveTmux[linux.id], ["keep-linux"])
        XCTAssertEqual(model.livenessAbandoned, 0)
    }

    func testFailedStaleRefreshDoesNotMarkTheComputerChecked() async {
        final class Clock: @unchecked Sendable {
            var date: Date
            init(_ date: Date) { self.date = date }
        }
        let clock = Clock(Self.listedAt)
        let mac = mac
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-\(UUID().uuidString).json"))
        let model = AppModel(store: TodoHubStore(cache: cache), demo: false, listTmux: { computer in
            if computer.id == mac.id { throw ListingFailed() }
            return ["keep-linux"]
        }, now: { clock.date })
        model.store.seedForDemo(
            todos: DemoFixtures.todos, conversations: DemoFixtures.conversations,
            sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
        )
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.livenessChecked[mac.id], Self.listedAt)
        XCTAssertNil(model.liveTmux[mac.id])
        XCTAssertEqual(model.liveTmux[linux.id], ["keep-linux"])

        let started = Conversation(
            todoId: "t7", computer: mac, cwd: "~/notes", tool: "claude", tmuxName: "todo-t7",
            sessionId: "s7", status: .busy, createdAt: "2026-10-18T00:00:05Z"
        )
        model.store.seedForDemo(
            todos: DemoFixtures.todos, conversations: DemoFixtures.conversations + [started],
            sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
        )
        let checkedLinux = model.livenessChecked[linux.id]
        clock.date = Self.listedAt.addingTimeInterval(10)
        await model.refreshLiveness(hosts: [], scope: .stale)
        XCTAssertNil(model.livenessChecked[mac.id])
        XCTAssertEqual(model.attachReadiness(forTodo: "t7"), .awaitingLiveness)
        XCTAssertNil(model.liveTmux[mac.id])
        XCTAssertEqual(model.livenessChecked[linux.id], checkedLinux)
        XCTAssertEqual(model.liveTmux[linux.id], ["keep-linux"])
    }

    func testFullRefreshWithNoComputersDoesNotSupersedeAnInFlightListing() async {
        let gate = Gate()
        let mode = Mode()
        let model = makeModel { _ in
            if await mode.slow {
                await gate.wait()
                return ["from-full"]
            }
            return ["listed"]
        }
        await mode.set(slow: true)
        let full = Task { await model.refreshLiveness(hosts: []) }
        while await gate.waiting < DemoFixtures.computers.count { await Task.yield() }
        model.store.seedForDemo(todos: [], conversations: [], sectionComputers: [], computers: [])
        await model.refreshLiveness(hosts: [])
        await gate.open()
        await full.value
        XCTAssertEqual(model.liveTmux[mac.id], ["from-full"])
        XCTAssertEqual(model.liveTmux[linux.id], ["from-full"])
        XCTAssertEqual(model.livenessAbandoned, 0)
    }

    func testFullRefreshWithNoHostsDoesNotStampChecks() async {
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-\(UUID().uuidString).json"))
        let model = AppModel(store: TodoHubStore(cache: cache), demo: false, now: { Self.listedAt })
        model.store.seedForDemo(
            todos: DemoFixtures.todos, conversations: DemoFixtures.conversations,
            sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
        )
        await model.refreshLiveness(hosts: [])
        XCTAssertTrue(model.livenessChecked.isEmpty)
        XCTAssertTrue(model.liveTmux.isEmpty)
        XCTAssertEqual(model.livenessAbandoned, 0)
    }

    func testAutomaticLivenessIDChangesWhenComputersOrHostsArrive() {
        let model = makeModel()
        let empty = model.automaticLivenessID(hostIDs: [])
        model.store.seedForDemo(todos: [], conversations: [], sectionComputers: [], computers: [])
        XCTAssertNotEqual(model.automaticLivenessID(hostIDs: []), empty)
        let host = UUID()
        XCTAssertNotEqual(model.automaticLivenessID(hostIDs: [host]), model.automaticLivenessID(hostIDs: []))
    }

    func testEmptyStaleRefreshDoesNotSupersedeAnInFlightListing() async {
        let gate = Gate()
        let mode = Mode()
        let model = makeModel { _ in
            if await mode.slow {
                await gate.wait()
                return ["from-full"]
            }
            return ["listed"]
        }
        await model.refreshLiveness(hosts: [])
        XCTAssertTrue(model.board.newerThanListing.isEmpty)
        await mode.set(slow: true)
        let full = Task { await model.refreshLiveness(hosts: []) }
        while await gate.waiting < DemoFixtures.computers.count { await Task.yield() }
        await model.refreshLiveness(hosts: [], scope: .stale)
        await gate.open()
        await full.value
        XCTAssertEqual(model.liveTmux[mac.id], ["from-full"])
        XCTAssertEqual(model.liveTmux[linux.id], ["from-full"])
        XCTAssertEqual(model.livenessAbandoned, 0)
    }

    /// A full listing already in flight must keep its result. The stale pass merges after it,
    /// and only for the computers it listed.
    func testStaleRefreshMergesAfterAnInFlightFullListing() async {
        let gate = Gate()
        let mode = Mode()
        let mac = mac
        let model = makeModel { computer in
            if await mode.staleMac, computer.id == mac.id { return ["from-stale"] }
            if await mode.slow {
                await gate.wait()
                return ["from-full"]
            }
            return ["before"]
        }
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.liveTmux[mac.id], ["before"])
        XCTAssertEqual(model.liveTmux[linux.id], ["before"])

        let started = Conversation(
            todoId: "t7", computer: mac, cwd: "~/notes", tool: "claude", tmuxName: "todo-t7",
            sessionId: "s7", status: .busy, createdAt: "2026-10-18T00:00:05Z"
        )
        model.store.seedForDemo(
            todos: DemoFixtures.todos, conversations: DemoFixtures.conversations + [started],
            sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
        )
        await mode.set(slow: true)
        let full = Task { await model.refreshLiveness(hosts: []) }
        while await gate.waiting == 0 { await Task.yield() }
        await mode.set(staleMac: true)
        await model.refreshLiveness(hosts: [], scope: .stale)
        await gate.open()
        await full.value
        XCTAssertEqual(model.liveTmux[linux.id], ["from-full"])
        XCTAssertEqual(model.liveTmux[mac.id], ["from-stale"])
        XCTAssertEqual(model.livenessAbandoned, 0)
    }

    /// A stale listing that throws is asked again. Recording the conversation before the
    /// listing returns leaves it unconfirmed until some other conversation goes stale.
    func testFailedStaleListingIsAskedAgain() async {
        let mac = mac
        let mode = Mode()
        let model = makeModel { computer in
            if computer.id == mac.id {
                if await mode.failMac { throw ListingFailed() }
                return ["mac-before"]
            }
            return ["keep-linux"]
        }
        model.staleRetryDelay = .zero
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.liveTmux[mac.id], ["mac-before"])
        await mode.set(failMac: true)
        let started = Conversation(
            todoId: "t7", computer: mac, cwd: "~/notes", tool: "claude", tmuxName: "todo-t7",
            sessionId: "s7", status: .busy, createdAt: "2026-10-18T00:00:05Z"
        )
        model.store.seedForDemo(
            todos: DemoFixtures.todos, conversations: DemoFixtures.conversations + [started],
            sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
        )
        await settle(model) { model.relistRequests > 0 }
        let asked = model.relistRequests
        await model.refreshLiveness(hosts: [], scope: .stale)
        XCTAssertEqual(model.liveTmux[mac.id], ["mac-before"], "a failed listing keeps the previous names")
        await settle(model) { model.relistRequests > asked }
        XCTAssertGreaterThan(model.relistRequests, asked)
    }

    private actor ListingCalls {
        private var ids: [String] = []
        func record(_ id: String) { ids.append(id) }
        func take() -> [String] {
            let taken = ids
            ids = []
            return taken
        }
    }

    private actor ListingPhase {
        var listingMac = false
        func setListingMac(_ listing: Bool) { listingMac = listing }
    }

    // MARK: "Needs you" alerts

    /// Records what the model would post or buzz instead of reaching the coordinator.
    private final class AlertRecorder {
        var posted: [WaitingAlert] = []
        var feedbacks = 0
        var enabled = true
        var frontmost: String?

        var alerts: WaitingAlerts {
            WaitingAlerts(
                isEnabled: { [unowned self] in enabled },
                frontmostTodoID: { [unowned self] in frontmost },
                post: { [unowned self] in posted.append($0) },
                feedback: { [unowned self] in feedbacks += 1 }
            )
        }
    }

    private func makeAlertingModel(_ recorder: AlertRecorder) -> AppModel {
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-\(UUID().uuidString).json"))
        return AppModel(store: TodoHubStore(cache: cache), demo: false, alerts: recorder.alerts)
    }

    /// The demo conversations with some statuses changed (t1 and t3 carry status messages).
    private func conversations(_ changes: [String: ConversationStatus] = [:]) -> [Conversation] {
        DemoFixtures.conversations.map { conversation in
            var conversation = conversation
            if let status = changes[conversation.todoId] { conversation.status = status }
            return conversation
        }
    }

    private func fetched(_ changes: [String: ConversationStatus], into model: AppModel) {
        model.store.applyFetched(todos: DemoFixtures.todos, conversations: conversations(changes))
    }

    private func assertNoConversationText(_ alerts: [WaitingAlert], file: StaticString = #filePath, line: UInt = #line) {
        let messages = DemoFixtures.conversations.compactMap(\.statusMessage)
        XCTAssertFalse(messages.isEmpty, "the fixtures must carry status messages", file: file, line: line)
        for alert in alerts {
            XCTAssertEqual(alert.body, "Needs you", file: file, line: line)
            for message in messages {
                XCTAssertFalse(alert.title.contains(message), file: file, line: line)
                XCTAssertFalse(alert.body.contains(message), file: file, line: line)
            }
        }
    }

    func testNotifiesOnlyOnTransition() {
        let recorder = AlertRecorder()
        let model = makeAlertingModel(recorder)
        fetched(["t1": .busy, "t3": .busy], into: model)
        fetched(["t1": .busy, "t3": .busy], into: model)
        XCTAssertTrue(recorder.posted.isEmpty, "nothing turned waiting")

        fetched(["t1": .waiting, "t3": .busy], into: model)
        XCTAssertEqual(recorder.posted.map(\.todoId), ["t1"])
        XCTAssertEqual(recorder.posted.first?.title, "Fix the rate import")
        XCTAssertEqual(recorder.posted.first?.sessionId, "demo-t1")

        fetched(["t1": .waiting, "t3": .busy], into: model)
        XCTAssertEqual(recorder.posted.count, 1, "still waiting is not a new transition")

        fetched(["t1": .busy, "t3": .waiting], into: model)
        fetched(["t1": .waiting, "t3": .waiting], into: model)
        XCTAssertEqual(recorder.posted.map(\.todoId), ["t1", "t3", "t1"])
        assertNoConversationText(recorder.posted)
        XCTAssertEqual(recorder.feedbacks, 0)
    }

    func testFirstSnapshotAfterLaunchAndReconnectNeverNotifies() {
        let recorder = AlertRecorder()
        let model = makeAlertingModel(recorder)
        fetched(["t1": .waiting, "t3": .waiting], into: model)
        XCTAssertTrue(recorder.posted.isEmpty, "already waiting at launch")

        fetched(["t1": .busy, "t3": .busy], into: model)
        // Reconnecting to the hub (settings) or the live-update socket dropping.
        model.store.startNewBaseline()
        fetched(["t1": .waiting, "t3": .busy], into: model)
        XCTAssertTrue(recorder.posted.isEmpty, "waiting by the time we reconnected")

        fetched(["t1": .waiting, "t3": .waiting], into: model)
        XCTAssertEqual(recorder.posted.map(\.todoId), ["t3"])
        assertNoConversationText(recorder.posted)
    }

    func testSuppressedWhenFrontmostUsesHaptic() {
        let recorder = AlertRecorder()
        recorder.frontmost = "t1"
        let model = makeAlertingModel(recorder)
        fetched(["t1": .busy, "t3": .busy], into: model)
        fetched(["t1": .waiting, "t3": .waiting], into: model)
        XCTAssertEqual(recorder.posted.map(\.todoId), ["t3"], "the conversation on screen is not alerted")
        XCTAssertEqual(recorder.feedbacks, 1)
        assertNoConversationText(recorder.posted)
    }

    func testSettingsToggleGatesAlertsAndHaptic() {
        let recorder = AlertRecorder()
        recorder.enabled = false
        recorder.frontmost = "t1"
        let model = makeAlertingModel(recorder)
        fetched(["t1": .busy, "t3": .busy], into: model)
        fetched(["t1": .waiting, "t3": .waiting], into: model)
        XCTAssertTrue(recorder.posted.isEmpty)
        XCTAssertEqual(recorder.feedbacks, 0)
        // Switched off, the baseline still moves on: switching on later doesn't alert old flips.
        recorder.enabled = true
        fetched(["t1": .waiting, "t3": .waiting], into: model)
        XCTAssertTrue(recorder.posted.isEmpty)
    }
}

// MARK: - Refresh coalescing and revision

@MainActor
final class TodoHubRefreshTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool, attempts: Int = 500) async {
        for _ in 0..<attempts where !condition() { await Task.yield() }
    }

    func testBackgroundBurstRunsOneRefreshAfterTheFirstDelay() async {
        let clock = ManualRefreshClock()
        let coalescer = TodoHubRefreshCoalescer(sleep: { try await clock.sleep($0) })
        var runs: [Bool] = []
        coalescer.onRefresh = { immediate in runs.append(immediate) }

        async let first: Void = coalescer.submit(immediate: false)
        async let second: Void = coalescer.submit(immediate: false)
        async let third: Void = coalescer.submit(immediate: false)
        await waitUntil { coalescer.submitted >= 3 && clock.pending >= 1 }

        XCTAssertEqual(coalescer.submitted, 3)
        XCTAssertEqual(clock.pending, 1, "a burst shares the first request's delay")
        XCTAssertEqual(clock.recordedDurations, [TodoHubRefreshCoalescer.window])
        XCTAssertTrue(runs.isEmpty, "nothing fetches before the window elapses")

        clock.advance()
        _ = await (first, second, third)
        XCTAssertEqual(runs, [false])

        async let again: Void = coalescer.submit(immediate: false)
        await waitUntil { coalescer.submitted >= 4 && clock.pending >= 1 }
        clock.advance()
        await again
        XCTAssertEqual(runs, [false, false], "a later burst fetches again")
        XCTAssertEqual(clock.recordedDurations, [TodoHubRefreshCoalescer.window, TodoHubRefreshCoalescer.window])
    }

    func testUserRefreshDoesNotWait() async {
        let clock = ManualRefreshClock()
        let coalescer = TodoHubRefreshCoalescer(sleep: { try await clock.sleep($0) })
        var runs: [Bool] = []
        coalescer.onRefresh = { immediate in runs.append(immediate) }

        await coalescer.submit(immediate: true)

        XCTAssertEqual(runs, [true])
        XCTAssertTrue(clock.recordedDurations.isEmpty)
        XCTAssertEqual(clock.pending, 0)
    }

    func testUserRefreshDuringTheBackgroundDelayRunsImmediately() async {
        let clock = ManualRefreshClock()
        let coalescer = TodoHubRefreshCoalescer(sleep: { try await clock.sleep($0) })
        var runs: [Bool] = []
        coalescer.onRefresh = { immediate in runs.append(immediate) }

        async let background: Void = coalescer.submit(immediate: false)
        await waitUntil { clock.pending >= 1 }
        XCTAssertEqual(clock.pending, 1)

        async let user: Void = coalescer.submit(immediate: true)
        _ = await (background, user)
        XCTAssertEqual(runs, [true], "the user refresh covers the pending burst")

        clock.advance()
        await waitUntil { clock.pending == 0 }
        XCTAssertEqual(runs, [true], "the cancelled window must not fetch again")
    }

    func testRequestsDuringAnInFlightRefreshRunExactlyOnceMore() async {
        let hold = RefreshHold()
        let coalescer = TodoHubRefreshCoalescer(sleep: { _ in })
        var runs: [Bool] = []
        coalescer.onRefresh = { immediate in
            runs.append(immediate)
            await hold.wait()
        }

        async let first: Void = coalescer.submit(immediate: true)
        await waitUntil { hold.entered >= 1 }
        XCTAssertEqual(runs, [true])

        async let during: Void = coalescer.submit(immediate: false)
        async let alsoDuring: Void = coalescer.submit(immediate: true)
        await waitUntil { coalescer.submitted >= 3 }
        XCTAssertEqual(runs.count, 1, "requests during a fetch must not start another one yet")

        hold.release()
        await waitUntil { hold.entered >= 2 }
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.last, true, "a user request during the fetch makes the single follow-up immediate")
        hold.release()
        _ = await (first, during, alsoDuring)
        XCTAssertEqual(runs.count, 2)
    }

    func testStoreBackgroundRefreshesShareOneFetch() async throws {
        HubRefreshStub.reset()
        let clock = ManualRefreshClock()
        let store = try makeStore(sleep: { try await clock.sleep($0) })
        HubRefreshStub.set { bodies in
            bodies.todos = Self.encoded(DemoFixtures.todos)
            bodies.conversations = Self.encoded(DemoFixtures.conversations)
        }

        async let first: Void = store.refresh(trigger: .background)
        async let second: Void = store.refresh(trigger: .background)
        await waitUntil { store.coalescer.submitted >= 2 && clock.pending >= 1 }
        XCTAssertEqual(store.coalescer.submitted, 2)
        XCTAssertEqual(clock.pending, 1)
        XCTAssertEqual(HubRefreshStub.hits, 0)

        clock.advance()
        _ = await (first, second)
        XCTAssertEqual(HubRefreshStub.hits, 6, "six hub calls, once for the burst")
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.backgroundIssue)
        XCTAssertEqual(store.todos.count, DemoFixtures.todos.count)
    }

    func testStoreUserRefreshFetchesImmediately() async throws {
        HubRefreshStub.reset()
        let clock = ManualRefreshClock()
        let store = try makeStore(sleep: { try await clock.sleep($0) })
        await store.refresh(trigger: .user)
        XCTAssertEqual(HubRefreshStub.hits, 6)
        XCTAssertTrue(clock.recordedDurations.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testStatusOnlyConversationUpdateDoesNotBumpRevision() async throws {
        HubRefreshStub.reset()
        let store = try makeStore()
        var conversations = DemoFixtures.conversations
        HubRefreshStub.set { bodies in
            bodies.todos = Self.encoded(DemoFixtures.todos)
            bodies.conversations = Self.encoded(conversations)
        }
        await store.refresh()
        let revision = store.revision
        XCTAssertGreaterThan(revision, 0, "the first snapshot's conversations are new")
        XCTAssertNil(store.errorMessage)

        conversations[0].status = conversations[0].status == .waiting ? .busy : .waiting
        HubRefreshStub.set { bodies in
            bodies.conversations = Self.encoded(conversations)
        }
        await store.refresh(trigger: .background)
        XCTAssertEqual(store.mostUrgent(forTodo: conversations[0].todoId)?.status, conversations[0].status)
        XCTAssertEqual(store.revision, revision, "a status heartbeat must not refetch project pages")

        conversations[0].statusMessage = "still working"
        HubRefreshStub.set { bodies in
            bodies.conversations = Self.encoded(conversations)
        }
        await store.refresh(trigger: .background)
        XCTAssertEqual(store.mostUrgent(forTodo: conversations[0].todoId)?.statusMessage, "still working")
        XCTAssertEqual(store.revision, revision)

        var renamed = DemoFixtures.todos
        renamed[0].title = "Renamed"
        HubRefreshStub.set { bodies in
            bodies.todos = Self.encoded(renamed)
        }
        await store.refresh(trigger: .background)
        XCTAssertEqual(store.todos.first { $0.id == renamed[0].id }?.title, "Renamed")
        XCTAssertEqual(store.revision, revision)

        HubRefreshStub.set { bodies in
            bodies.computers = Self.encoded([DemoFixtures.macStudio])
        }
        await store.refresh(trigger: .background)
        XCTAssertEqual(store.computers.map(\.id), [DemoFixtures.macStudio.id])
        XCTAssertEqual(store.revision, revision)

        await store.refresh(trigger: .user)
        XCTAssertGreaterThan(store.revision, revision, "pull to refresh reloads project conversations and memories")
        XCTAssertNil(store.errorMessage)
    }

    func testConversationIdentityAndProjectChangesBumpRevision() async throws {
        HubRefreshStub.reset()
        let store = try makeStore()
        var conversations = DemoFixtures.conversations
        HubRefreshStub.set { bodies in
            bodies.todos = Self.encoded(DemoFixtures.todos)
            bodies.conversations = Self.encoded(conversations)
        }
        await store.refresh()
        var revision = store.revision
        XCTAssertNil(store.errorMessage)

        conversations[0].sessionId = "replaced-session"
        HubRefreshStub.set { bodies in
            bodies.conversations = Self.encoded(conversations)
        }
        await store.refresh()
        XCTAssertGreaterThan(store.revision, revision, "a new session id is a different conversation")
        revision = store.revision

        let removed = conversations.removeLast()
        HubRefreshStub.set { bodies in
            bodies.conversations = Self.encoded(conversations)
        }
        await store.refresh()
        XCTAssertNil(store.mostUrgent(forTodo: removed.todoId))
        XCTAssertGreaterThan(store.revision, revision)
        revision = store.revision

        let project = Project(
            id: "p1", name: "Notes", computer: DemoFixtures.macStudio, folder: "/tmp/notes", openTodos: 1
        )
        HubRefreshStub.set { bodies in
            bodies.projects = Self.encoded([project])
        }
        await store.refresh()
        XCTAssertEqual(store.projects.map(\.id), ["p1"])
        XCTAssertGreaterThan(store.revision, revision)
        revision = store.revision

        HubRefreshStub.set { bodies in
            bodies.suggestions = Self.suggestionJSON(folder: "/tmp/notes")
        }
        await store.refresh()
        XCTAssertEqual(store.suggestions.map(\.folder), ["/tmp/notes"])
        XCTAssertGreaterThan(store.revision, revision)
        XCTAssertNil(store.errorMessage)
    }

    func testIdenticalSnapshotSkipsTheCacheWrite() async throws {
        HubRefreshStub.reset()
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-hub-refresh-\(UUID().uuidString).json"))
        let store = try makeStore(cache: cache)
        HubRefreshStub.set { bodies in
            bodies.todos = Self.encoded(DemoFixtures.todos)
            bodies.conversations = Self.encoded(DemoFixtures.conversations)
        }
        await store.refresh()
        XCTAssertEqual(store.cacheSaveCount, 1)
        let saved = cache.load()
        XCTAssertEqual(saved?.todos, DemoFixtures.todos)
        XCTAssertEqual(saved?.conversations, DemoFixtures.conversations)
        let savedAt = saved?.savedAt

        await store.refresh()
        XCTAssertEqual(store.cacheSaveCount, 1, "the same todos, conversations, and projects are not written again")
        XCTAssertEqual(cache.load()?.savedAt, savedAt)

        var conversations = DemoFixtures.conversations
        conversations[0].status = .busy
        HubRefreshStub.set { bodies in
            bodies.conversations = Self.encoded(conversations)
        }
        await store.refresh()
        XCTAssertEqual(store.cacheSaveCount, 2, "a status change is still cached for offline display")
        XCTAssertEqual(cache.load()?.conversations.first { $0.todoId == conversations[0].todoId }?.status, .busy)
        XCTAssertNil(store.errorMessage)
    }

    private func makeStore(
        cache: TodoHubCache? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) throws -> TodoHubStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HubRefreshStub.self]
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        let client = TodoHubClient(baseURL: URL(string: "http://hub.invalid")!, token: "t", session: session)
        let cache = cache ?? TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-hub-refresh-\(UUID().uuidString).json"))
        return TodoHubStore(cache: cache, makeClient: { client }, sleep: sleep)
    }

    private static func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? encoder.encode(value)) ?? Data("[]".utf8)
    }

    private static func suggestionJSON(folder: String) -> Data {
        let computer = String(data: encoded(DemoFixtures.macStudio), encoding: .utf8) ?? "{}"
        return Data("""
        [{"computer":\(computer),"folder":"\(folder)","name":"notes","sessions":1,"example_cwds":[]}]
        """.utf8)
    }
}

/// Suspends until `advance()`. A cancelled sleeper throws `CancellationError` instead of firing late.
private final class ManualRefreshClock: @unchecked Sendable {
    private final class Slot {
        enum Outcome { case success, cancelled }
        var continuation: CheckedContinuation<Void, Error>?
        var outcome: Outcome?
    }

    private let lock = NSLock()
    private var slots: [Slot] = []
    private var durations: [Duration] = []

    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.filter { $0.outcome == nil && $0.continuation != nil }.count
    }

    var recordedDurations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return durations
    }

    func sleep(_ duration: Duration) async throws {
        let slot = beginSleep(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.store(cont, in: slot)
            }
        } onCancel: {
            self.finish(slot, outcome: .cancelled)
        }
    }

    private func beginSleep(_ duration: Duration) -> Slot {
        let slot = Slot()
        lock.lock()
        durations.append(duration)
        slots.append(slot)
        lock.unlock()
        return slot
    }

    func advance() {
        lock.lock()
        let pending = slots.filter { $0.outcome == nil }
        lock.unlock()
        for slot in pending { finish(slot, outcome: .success) }
    }

    private func store(_ continuation: CheckedContinuation<Void, Error>, in slot: Slot) {
        lock.lock()
        if let outcome = slot.outcome {
            lock.unlock()
            resume(continuation, outcome: outcome)
            return
        }
        slot.continuation = continuation
        lock.unlock()
    }

    private func finish(_ slot: Slot, outcome: Slot.Outcome) {
        lock.lock()
        guard slot.outcome == nil else {
            lock.unlock()
            return
        }
        slot.outcome = outcome
        let continuation = slot.continuation
        lock.unlock()
        if let continuation { resume(continuation, outcome: outcome) }
    }

    private func resume(_ continuation: CheckedContinuation<Void, Error>, outcome: Slot.Outcome) {
        switch outcome {
        case .success: continuation.resume()
        case .cancelled: continuation.resume(throwing: CancellationError())
        }
    }
}

/// Blocks inside a refresh until `release()`, and counts how many refreshes have entered.
private final class RefreshHold: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var entered: Int {
        lock.lock()
        defer { lock.unlock() }
        return enteredCount
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            enteredCount += 1
            waiters.append(cont)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
        lock.unlock()
        waiter?.resume()
    }
}

/// Canned hub lists for store refresh tests. Not isolated: `URLProtocol` calls in on a session queue.
private final class HubRefreshStub: URLProtocol, @unchecked Sendable {
    struct Bodies {
        var todos = Data("[]".utf8)
        var conversations = Data("[]".utf8)
        var sectionComputers = Data("[]".utf8)
        var computers = Data("[]".utf8)
        var projects = Data("[]".utf8)
        var suggestions = Data("[]".utf8)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) static var hits = 0
    nonisolated(unsafe) static var bodies = Bodies()

    static func reset() {
        lock.lock()
        hits = 0
        bodies = Bodies()
        lock.unlock()
    }

    static func set(_ update: (inout Bodies) -> Void) {
        lock.lock()
        update(&bodies)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.hits += 1
        let body: Data
        switch path {
        case "/api/todos": body = Self.bodies.todos
        case "/api/conversations": body = Self.bodies.conversations
        case "/api/sections/computers": body = Self.bodies.sectionComputers
        case "/api/computers": body = Self.bodies.computers
        case "/api/projects": body = Self.bodies.projects
        case "/api/projects/suggestions": body = Self.bodies.suggestions
        default:
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"missing"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": "application/json"
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
