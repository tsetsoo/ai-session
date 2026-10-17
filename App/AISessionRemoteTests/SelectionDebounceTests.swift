import AISessionCore
import XCTest
@testable import AISessionRemote

/// Selecting on the Mac attaches only to a running conversation, 150 ms after the selection
/// settles, and only once its computer's tmux sessions are known.
@MainActor
final class SelectionDebounceTests: XCTestCase {
    /// Collects scheduled callbacks so a test decides when the debounce window elapses.
    @MainActor
    private final class ManualScheduler {
        var pending: [@MainActor () -> Void] = []
        func run() {
            let callbacks = pending
            pending = []
            callbacks.forEach { $0() }
        }
    }

    private var scheduler = ManualScheduler()
    private var readiness: [String: AttachReadiness] = [:]
    private var requests: [FrameRequest] = []
    private var attacher: SelectionAttacher!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        readiness = [:]
        requests = []
        attacher = SelectionAttacher(scheduler: { [scheduler] in scheduler.pending.append($0) })
        attacher.readiness = { [unowned self] in self.readiness[$0] ?? .closed }
        attacher.perform = { [unowned self] in self.requests.append($0) }
    }

    private var sent: [String] {
        requests.map { request in
            switch request.kind {
            case .attach: "attach \(request.todoID)"
            case .detach: "detach \(request.todoID)"
            case .start: "start \(request.todoID)"
            }
        }
    }

    // MARK: Debounce

    func testThreeQuickSelectionsAttachOnceToTheLast() {
        readiness = ["a": .running, "b": .running, "c": .running]
        attacher.select("a")
        attacher.select("b")
        attacher.select("c")
        XCTAssertTrue(attacher.isSettling)
        XCTAssertEqual(sent, [])
        scheduler.run()
        XCTAssertEqual(sent, ["attach c"])
        XCTAssertFalse(attacher.isSettling)
    }

    func testTheDebounceIs150Milliseconds() {
        XCTAssertEqual(SelectionAttacher.delay, 0.15)
    }

    func testSelectingAClosedConversationNeverStartsOrAttaches() {
        readiness = ["a": .closed]
        attacher.select("a")
        scheduler.run()
        XCTAssertEqual(sent, [])
    }

    func testClearingTheSelectionCancelsThePendingAttach() {
        readiness = ["a": .running]
        attacher.select("a")
        attacher.select(nil)
        scheduler.run()
        XCTAssertEqual(sent, [])
    }

    // MARK: Liveness wait

    func testWaitsForLivenessThenAttaches() {
        readiness = ["a": .awaitingLiveness]
        attacher.select("a")
        scheduler.run()
        XCTAssertEqual(sent, [])
        XCTAssertEqual(attacher.livenessRequests, 1)

        // The refresh answered and the session is alive.
        readiness["a"] = .running
        attacher.inputsChanged()
        scheduler.run()
        XCTAssertEqual(sent, ["attach a"])
    }

    func testAsksForLivenessOncePerSelection() {
        readiness = ["a": .awaitingLiveness]
        attacher.select("a")
        scheduler.run()
        attacher.inputsChanged()
        scheduler.run()
        XCTAssertEqual(attacher.livenessRequests, 1)
    }

    func testUnreachableComputerAfterTheRefreshShowsStartInsteadOfAttaching() {
        readiness = ["a": .awaitingLiveness]
        attacher.select("a")
        scheduler.run()
        // The refresh finished without an answer for the computer: attaching could recreate a
        // dead session, so stay on the Start / Resume card.
        readiness["a"] = .unknown
        attacher.inputsChanged()
        scheduler.run()
        XCTAssertEqual(sent, [])
    }

    // MARK: Re-evaluation

    func testAConversationThatStartsRunningElsewhereAttachesDebounced() {
        readiness = ["a": .closed]
        attacher.select("a")
        scheduler.run()
        readiness["a"] = .running
        attacher.inputsChanged()
        XCTAssertEqual(sent, [])
        XCTAssertTrue(attacher.isSettling)
        scheduler.run()
        XCTAssertEqual(sent, ["attach a"])
    }

    func testAConversationThatClosesDropsToTheIdleCard() {
        readiness = ["a": .running]
        attacher.select("a")
        scheduler.run()
        readiness["a"] = .closed
        attacher.inputsChanged()
        scheduler.run()
        XCTAssertEqual(sent, ["attach a", "detach a"])
    }

    func testAComputerThatStopsAnsweringKeepsTheAttachedConversation() {
        readiness = ["a": .running]
        attacher.select("a")
        scheduler.run()
        readiness["a"] = .unknown
        attacher.inputsChanged()
        scheduler.run()
        XCTAssertEqual(sent, ["attach a"])
        // …and a close seen after the gap still drops it.
        readiness["a"] = .closed
        attacher.inputsChanged()
        scheduler.run()
        XCTAssertEqual(sent, ["attach a", "detach a"])
    }

    func testAStillClosedConversationIsNotDetached() {
        // An explicit start on a closed conversation: the board can lag behind, still showing
        // it closed. That is no transition, so the started terminal stays.
        readiness = ["a": .closed]
        attacher.select("a")
        scheduler.run()
        attacher.inputsChanged()
        scheduler.run()
        XCTAssertEqual(sent, [])
    }

    func testReselectAttachesAgain() {
        // Bring Back: the main window attaches again under the same rules.
        readiness = ["a": .running]
        attacher.select("a")
        scheduler.run()
        attacher.reselect()
        scheduler.run()
        XCTAssertEqual(sent, ["attach a", "attach a"])
    }

    func testReselectingTheSameTodoDoesNotReattach() {
        readiness = ["a": .running]
        attacher.select("a")
        scheduler.run()
        attacher.select("a")
        scheduler.run()
        XCTAssertEqual(sent, ["attach a"])
    }

    // MARK: Readiness from the board

    private struct ListingFailed: Error {}

    /// The time the model lists at and judges a listing's age by.
    private final class Clock {
        var now = ISO8601DateFormatter().date(from: "2026-10-18T00:00:00Z")!
    }

    private func makeModel(clock: Clock = Clock(),
                           listTmux: @escaping @Sendable (Computer) async throws -> Set<String>) -> AppModel {
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-\(UUID().uuidString).json"))
        let model = AppModel(store: TodoHubStore(cache: cache), demo: false, listTmux: listTmux,
                             now: { clock.now })
        model.store.seedForDemo(
            todos: DemoFixtures.todos, conversations: DemoFixtures.conversations,
            sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
        )
        return model
    }

    func testReadinessWaitsForTheFirstLivenessAnswer() async {
        // t1 runs on mac-studio, t3 on linux-box, t7 has no conversation.
        let model = makeModel { computer in
            if computer.id == DemoFixtures.macStudio.id { return ["todo-t1"] }
            throw ListingFailed()
        }
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .awaitingLiveness)
        XCTAssertEqual(model.attachReadiness(forTodo: "t7"), .closed)
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .running)
        XCTAssertEqual(model.attachReadiness(forTodo: "t2"), .closed)   // tmux session gone
        XCTAssertEqual(model.attachReadiness(forTodo: "t3"), .unknown)  // linux-box didn't answer
    }

    func testAnOldListingIsCheckedAgainBeforeAttaching() async {
        let clock = Clock()
        let model = makeModel(clock: clock) { _ in ["todo-t1"] }
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .running)
        clock.now += AppModel.listingMaxAge
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .running)
        clock.now += 1
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .awaitingLiveness)
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .running)
    }

    /// The computer rebooted after the last listing: the hub still says busy, and attaching
    /// would recreate the session. Selecting it waits, lists again and never attaches.
    func testSelectionAfterARebootListsAgainAndNeverAttaches() async {
        let clock = Clock()
        let rebooted = Rebooted()
        let model = makeModel(clock: clock) { _ in await rebooted.value ? [] : ["todo-t1", "todo-t2"] }
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .running)

        await rebooted.set()
        clock.now += AppModel.listingMaxAge + 1
        attacher.readiness = { model.attachReadiness(forTodo: $0) }
        attacher.select("t1")
        scheduler.run()
        XCTAssertEqual(attacher.livenessRequests, 1)
        XCTAssertEqual(sent, [])
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .closed)
        attacher.inputsChanged()
        scheduler.run()
        XCTAssertEqual(sent, [])
    }

    /// Started after its computer's listing: not closed, but not attached on the hub's word
    /// either, until a listing shows it.
    func testAConversationNewerThanTheListingWaitsForIt() async {
        let clock = Clock()
        let listing = Listing()
        let model = makeModel(clock: clock) { _ in await listing.names }
        await model.refreshLiveness(hosts: [])
        let started = Conversation(
            todoId: "t7", computer: DemoFixtures.macStudio, cwd: "~/notes", tool: "claude",
            tmuxName: "todo-t7", sessionId: "s7", status: .busy, createdAt: "2026-10-18T00:00:05Z"
        )
        model.store.seedForDemo(
            todos: DemoFixtures.todos, conversations: DemoFixtures.conversations + [started],
            sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
        )
        clock.now += 10
        XCTAssertEqual(model.board.status(forTodo: "t7"), .working)
        XCTAssertEqual(model.attachReadiness(forTodo: "t7"), .unknown)
        await listing.set(["todo-t7"])
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.attachReadiness(forTodo: "t7"), .running)
    }

    private actor Rebooted {
        private(set) var value = false
        func set() { value = true }
    }

    private actor Listing {
        private(set) var names: Set<String> = []
        func set(_ names: Set<String>) { self.names = names }
    }

    /// Parks listings until opened, so a test controls which refresh finishes first.
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

    /// Counts calls to the tmux listing.
    private actor Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    /// Stands in for the detail views: runs a liveness refresh for each attacher whose
    /// `livenessRequests` went up (its `.task(id:)`), passes on `livenessAbandoned`, and
    /// re-evaluates (its `onChange(of: readiness)`), for a few rounds. Returns the refreshes run.
    private func driveDetails(_ attachers: [SelectionAttacher], model: AppModel, rounds: Int = 5) async -> Int {
        var ran = attachers.map { _ in 0 }
        var abandoned = model.livenessAbandoned
        var refreshes = 0
        for _ in 0..<rounds {
            var tasks: [Task<Void, Never>] = []
            for (i, attacher) in attachers.enumerated() where attacher.livenessRequests > ran[i] {
                ran[i] = attacher.livenessRequests
                refreshes += 1
                tasks.append(Task { await model.refreshLiveness(hosts: []) })
            }
            for task in tasks { await task.value }
            if model.livenessAbandoned != abandoned {
                abandoned = model.livenessAbandoned
                attachers.forEach { $0.livenessAbandoned() }
            }
            attachers.forEach { $0.inputsChanged() }
            scheduler.run()
        }
        return refreshes
    }

    func testASupersededThenCancelledRefreshAsksAgainAndStillAttaches() async {
        let gate = Gate()
        let mac = DemoFixtures.macStudio
        let model = makeModel { computer in
            await gate.wait()
            if computer.id == mac.id { return ["todo-t1"] }
            throw ListingFailed()
        }
        attacher.readiness = { model.attachReadiness(forTodo: $0) }
        attacher.select("t1")
        scheduler.run()
        XCTAssertEqual(attacher.livenessRequests, 1)

        // The detail's refresh (generation N) is superseded by another view's (N + 1), say the
        // sidebar's, which is then cancelled: neither publishes.
        let detail = Task { await model.refreshLiveness(hosts: []) }
        while await gate.waiting < 2 { await Task.yield() }
        let other = Task { await model.refreshLiveness(hosts: []) }
        while await gate.waiting < 4 { await Task.yield() }
        other.cancel()
        await gate.open()
        await detail.value
        await other.value
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .awaitingLiveness)
        XCTAssertEqual(model.livenessAbandoned, 1)

        // Still waiting, so the detail asks again instead of staying on "Connecting to …".
        attacher.livenessAbandoned()
        XCTAssertEqual(attacher.livenessRequests, 2)
        XCTAssertEqual(sent, [])
        await model.refreshLiveness(hosts: [])
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .running)
        XCTAssertEqual(model.livenessAbandoned, 1)
        attacher.inputsChanged()
        scheduler.run()
        XCTAssertEqual(sent, ["attach t1"])
    }

    func testTwoWaitingFramesDoNotSupersedeEachOtherForever() async {
        // The main window's detail and a pop-out both wait on a computer that never answers:
        // each one's refresh runs while the other's is in flight, and the newer supersedes the
        // older. Neither may ask again because of that.
        let gate = Gate()
        let listings = Counter()
        let model = makeModel { _ in
            await listings.bump()
            await gate.wait()
            throw ListingFailed()
        }
        let second = SelectionAttacher(scheduler: { [scheduler] in scheduler.pending.append($0) })
        var secondSent: [FrameRequest] = []
        second.perform = { secondSent.append($0) }
        let attachers: [SelectionAttacher] = [attacher, second]
        for each in attachers {
            each.readiness = { model.attachReadiness(forTodo: $0) }
            each.select("t1")
        }
        scheduler.run()
        XCTAssertEqual(attachers.map(\.livenessRequests), [1, 1])

        let opener = Task {
            while await gate.waiting < 4 { await Task.yield() }
            await gate.open()
        }
        let refreshes = await driveDetails(attachers, model: model)
        await opener.value

        XCTAssertEqual(refreshes, 2)
        let listed = await listings.count
        XCTAssertEqual(listed, 4)   // two refreshes × two computers, and no more
        XCTAssertEqual(model.livenessAbandoned, 0)
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .unknown)
        XCTAssertEqual(sent, [])
        XCTAssertEqual(secondSent, [])
        XCTAssertEqual(attachers.map(\.livenessRequests), [1, 1])
    }

    func testAPoppedOutDetailDoesNotAskForLiveness() {
        readiness = ["a": .awaitingLiveness]
        attacher.isSuspended = true
        attacher.select("a")
        scheduler.run()
        attacher.livenessAbandoned()
        XCTAssertEqual(attacher.livenessRequests, 0)
        // Brought back: it asks then.
        attacher.isSuspended = false
        attacher.reselect()
        scheduler.run()
        XCTAssertEqual(attacher.livenessRequests, 1)
    }

    func testDemoLaunchesKnowTheirLiveness() {
        let model = AppModel(demo: true)
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .running)
        XCTAssertEqual(model.attachReadiness(forTodo: "t4"), .running)
        XCTAssertEqual(model.attachReadiness(forTodo: "t7"), .closed)
    }
}
