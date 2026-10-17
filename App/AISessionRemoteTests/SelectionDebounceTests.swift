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

    private func makeModel(listTmux: @escaping @Sendable (Computer) async throws -> Set<String>) -> AppModel {
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-\(UUID().uuidString).json"))
        let model = AppModel(store: TodoHubStore(cache: cache), demo: false, listTmux: listTmux)
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

    func testDemoLaunchesKnowTheirLiveness() {
        let model = AppModel(demo: true)
        XCTAssertEqual(model.attachReadiness(forTodo: "t1"), .running)
        XCTAssertEqual(model.attachReadiness(forTodo: "t4"), .running)
        XCTAssertEqual(model.attachReadiness(forTodo: "t7"), .closed)
    }
}
