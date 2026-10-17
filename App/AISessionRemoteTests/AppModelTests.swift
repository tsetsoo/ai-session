import AISessionCore
import XCTest
@testable import AISessionRemote

@MainActor
final class AppModelTests: XCTestCase {
    private struct ListingFailed: Error {}

    private let mac = DemoFixtures.macStudio
    private let linux = DemoFixtures.linuxBox

    private func makeModel(listTmux: @escaping (Computer) async throws -> Set<String> = { _ in [] }) -> AppModel {
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-\(UUID().uuidString).json"))
        let model = AppModel(store: TodoHubStore(cache: cache), demo: false, listTmux: listTmux)
        model.store.seedForDemo(
            todos: DemoFixtures.todos, conversations: DemoFixtures.conversations,
            sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
        )
        return model
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
