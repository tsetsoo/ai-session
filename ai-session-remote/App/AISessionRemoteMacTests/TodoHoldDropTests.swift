import AISessionCore
import XCTest
@testable import AI_Session_Remote

@MainActor
final class TodoHoldDropTests: XCTestCase {
    private func store() throws -> TodoHubStore {
        let todos = [
            Todo(id: "active", section: .sp, title: "Continue later", projectId: "project"),
            Todo(id: "done", section: .sp, title: "Finished", completed: true),
            Todo(id: "held", section: .sp, title: "Already paused", onHold: true),
        ]
        HoldDropHub.reset(todos)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID()).json")
        let cache = TodoHubCache(fileURL: path)
        try cache.save(TodoHubSnapshot(todos: todos, conversations: []))
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HoldDropHub.self]
        let client = TodoHubClient(baseURL: URL(string: "http://drop.invalid")!, token: "test",
                                   session: URLSession(configuration: config))
        return TodoHubStore(cache: cache, makeClient: { client }, sleep: { _ in })
    }

    func testOnlyActiveTodosAreDraggableAndOnlyWhileOnline() {
        let active = Todo(id: "active", section: .sp, title: "a")
        XCTAssertTrue(TodoHoldDrop.canDrag(active, isOffline: false))
        XCTAssertFalse(TodoHoldDrop.canDrag(active, isOffline: true))
        XCTAssertFalse(TodoHoldDrop.canDrag(Todo(id: "d", section: .sp, title: "d", completed: true), isOffline: false))
        XCTAssertFalse(TodoHoldDrop.canDrag(Todo(id: "h", section: .sp, title: "h", onHold: true), isOffline: false))
        XCTAssertFalse(TodoHoldDrop.canDrag(nil, isOffline: false))
    }

    func testDropUpdatesOneTodoForDuplicateConversationPayloadsAndPreservesItsProject() async throws {
        let store = try store()
        let refreshed = expectation(description: "Drop saved to hub and refreshed")
        store.onRefresh = { _ in refreshed.fulfill() }
        let accepted = TodoHoldDrop.accept(
            ["active", "active", "done", "held", "missing"].map { TodoDragItem(todoID: $0).itemProvider() }, store: store
        )
        XCTAssertTrue(accepted)
        await fulfillment(of: [refreshed], timeout: 3)
        XCTAssertEqual(HoldDropHub.patchedIDs, ["active"])
        let updated = try XCTUnwrap(store.todos.first { $0.id == "active" })
        XCTAssertTrue(updated.onHold)
        XCTAssertEqual(updated.title, "Continue later")
        XCTAssertEqual(updated.projectId, "project")
        XCTAssertFalse(updated.completed)
    }

    func testDropRejectsUnknownCompletedAlreadyHeldAndEmptyPayloads() throws {
        let store = try store()
        for ids in [[], ["missing"], ["done"], ["held"]] {
            XCTAssertFalse(TodoHoldDrop.accept(ids.map { TodoDragItem(todoID: $0) }, store: store))
        }
        XCTAssertFalse(TodoHoldDrop.accept([NSItemProvider(object: "active" as NSString)], store: store))
        XCTAssertTrue(HoldDropHub.patchedIDs.isEmpty)
    }

    func testDropDoesNotChangeCachedTodosWhileOffline() async throws {
        let store = try store()
        HoldDropHub.goOffline()
        await store.refresh(trigger: .background)
        XCTAssertTrue(store.isOffline)
        XCTAssertFalse(TodoHoldDrop.accept([TodoDragItem(todoID: "active")], store: store))
        XCTAssertFalse(try XCTUnwrap(store.todos.first { $0.id == "active" }).onHold)
        XCTAssertTrue(HoldDropHub.patchedIDs.isEmpty)
    }
}

private final class HoldDropHub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var todos: [Todo] = []
    nonisolated(unsafe) private static var patches: [String] = []
    nonisolated(unsafe) private static var offline = false

    static func reset(_ values: [Todo]) {
        lock.lock(); defer { lock.unlock() }
        todos = values
        patches = []
        offline = false
    }

    static func goOffline() {
        lock.lock(); defer { lock.unlock() }
        offline = true
    }

    static var patchedIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return patches
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "drop.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        if Self.offline {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data: Data
        if request.httpMethod == "PATCH", let id = request.url?.lastPathComponent,
           let index = Self.todos.firstIndex(where: { $0.id == id }) {
            Self.patches.append(id)
            Self.todos[index].onHold = true
            data = try! encoder.encode(Self.todos[index])
        } else if request.url?.path == "/api/todos" {
            data = try! encoder.encode(Self.todos)
        } else {
            data = Data("[]".utf8)
        }
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
