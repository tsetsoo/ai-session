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
}
