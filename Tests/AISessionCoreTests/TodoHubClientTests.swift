import XCTest
@testable import AISessionCore

/// Serves canned responses and records requests for `TodoHubClient` tests.
final class StubURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var body: String
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Response)?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        // URLSession moves bodies into a stream; capture it so tests can assert on it.
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBody = data
        }
        Self.requests.append(recorded)
        let response = Self.handler?(recorded) ?? Response(status: 500, body: "{}")
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TodoHubClientTests: XCTestCase {
    // Captured from a live todo-server (todo-app PR #1) smoke test.
    static let conversationJSON = """
    {"todo_id":"4f3ff5fa-c99d-4fb0-b15f-734eb42d0f3f","computer":{"id":"f3dde920-1744-4b76-9104-2c2b078ee3d9","name":"Mac","hostname":"mac.tailnet","port":22,"username":"me","created_at":"2026-10-15 20:17:27","updated_at":"2026-10-15 20:17:27"},"cwd":"~/programming","tool":"claude","tmux_name":"ai/claude/todo-4f3ff5fa","claude_session_id":"20218a19-fdb7-4835-9c7f-ed31b2fd4423","status":"unknown","status_message":null,"status_updated_at":null,"created_at":"2026-10-15 20:17:27"}
    """

    static let todosJSON = """
    [{"id":"4f3ff5fa-c99d-4fb0-b15f-734eb42d0f3f","section":"I","title":"Spec work","completed":false,"importance":"medium","due_date":null,"daily_date":null,"carried_from":null,"created_at":"2026-10-15 20:17:27","updated_at":"2026-10-15 20:17:27","completed_at":null,"conversation_status":"waiting"},
     {"id":"11111111-2222-4333-8444-555555555555","section":"Sp","title":"legacy","completed":false,"importance":"medium","due_date":null,"daily_date":null,"carried_from":null,"created_at":"2026-10-15 20:17:44","updated_at":"2026-10-15 20:17:44","completed_at":null}]
    """

    static let sectionComputersJSON = """
    [{"section":"I","computer":{"id":"f3dde920-1744-4b76-9104-2c2b078ee3d9","name":"Mac","hostname":"mac.tailnet","port":22,"username":"me","created_at":"2026-10-15 20:17:27","updated_at":"2026-10-15 20:17:27"},"cwd":"~/programming","tool":"claude"}]
    """

    private func client(token: String? = "s3cret") -> TodoHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return TodoHubClient(baseURL: URL(string: "http://pi.tailnet:8080")!, token: token, session: URLSession(configuration: config))
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.requests = []
        StubURLProtocol.handler = nil
    }

    func testDecodesTodosWithOptionalConversationStatus() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: Self.todosJSON) }
        let todos = try await client().listTodos(section: .i, filter: .all)
        XCTAssertEqual(todos.count, 2)
        XCTAssertEqual(todos[0].section, .i)
        XCTAssertEqual(todos[0].conversationStatus, .waiting)
        XCTAssertEqual(todos[1].section, .sp)
        XCTAssertNil(todos[1].conversationStatus)

        let url = try XCTUnwrap(StubURLProtocol.requests.first?.url)
        XCTAssertEqual(url.path, "/api/todos")
        XCTAssertEqual(url.query, "section=I&show=all")
    }

    func testDecodesConversationAndSectionMapping() async throws {
        StubURLProtocol.handler = { request in
            request.url!.path.hasSuffix("/conversation")
                ? .init(status: 200, body: Self.conversationJSON)
                : .init(status: 200, body: Self.sectionComputersJSON)
        }
        let conversation = try await client().openConversation(todoId: "4f3ff5fa-c99d-4fb0-b15f-734eb42d0f3f")
        XCTAssertEqual(conversation.tmuxName, "ai/claude/todo-4f3ff5fa")
        XCTAssertEqual(conversation.sessionId, "20218a19-fdb7-4835-9c7f-ed31b2fd4423")
        XCTAssertEqual(conversation.computer.hostname, "mac.tailnet")
        XCTAssertEqual(conversation.status, .unknown)
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "POST")

        let mappings = try await client().listSectionComputers()
        XCTAssertEqual(mappings.first?.section, .i)
        XCTAssertEqual(mappings.first?.cwd, "~/programming")
    }

    func testSendsBearerTokenExceptOnHealth() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: "[]") }
        _ = try await client().listComputers()
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer s3cret")

        StubURLProtocol.handler = { _ in .init(status: 200, body: #"{"ok":true}"#) }
        try await client().health()
        XCTAssertNil(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"))

        _ = try? await client(token: "  ").listComputers()
        XCTAssertNil(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"))
    }

    func testEncodesSnakeCaseBodies() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: Self.sectionComputersJSON.dropFirst().dropLast().description) }
        _ = try await client().setSectionComputer(.i, SetSectionComputerRequest(computerId: "m1", cwd: "~/x"))
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/api/sections/I/computer")
        let body = try XCTUnwrap(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["computer_id"] as? String, "m1")
        XCTAssertEqual(body["cwd"] as? String, "~/x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testMapsErrorStatuses() async {
        StubURLProtocol.handler = { _ in .init(status: 401, body: #"{"error":"Missing or invalid API token"}"#) }
        await XCTAssertThrowsHubError(try await client().listTodos(), .unauthorized)

        StubURLProtocol.handler = { _ in .init(status: 409, body: #"{"error":"Section P has no computer assigned"}"#) }
        await XCTAssertThrowsHubError(
            try await client().openConversation(todoId: "t"), .conflict("Section P has no computer assigned")
        )
        // Other 409s keep their own text; the UI must not assume "no computer".
        StubURLProtocol.handler = { _ in .init(status: 409, body: #"{"error":"No free tmux session name for this todo"}"#) }
        await XCTAssertThrowsHubError(
            try await client().openConversation(todoId: "t"), .conflict("No free tmux session name for this todo")
        )
        XCTAssertEqual(
            TodoHubError.conflict("No free tmux session name for this todo").userMessage,
            "No free tmux session name for this todo"
        )

        StubURLProtocol.handler = { _ in .init(status: 404, body: #"{"error":"Todo not found"}"#) }
        await XCTAssertThrowsHubError(try await client().deleteTodo(id: "t"), .notFound("Todo not found"))

        StubURLProtocol.handler = { _ in .init(status: 500, body: "boom") }
        await XCTAssertThrowsHubError(
            try await client().listTodos(), .server(status: 500, message: "internal server error")
        )
    }

    func testMissingConversationIsNil() async throws {
        StubURLProtocol.handler = { _ in .init(status: 404, body: #"{"error":"Todo has no conversation"}"#) }
        let conversation = try await client().conversation(todoId: "t")
        XCTAssertNil(conversation)
    }

    func testBaseURLParsing() {
        XCTAssertEqual(TodoHubClient.baseURL(from: "100.118.255.23:8080")?.absoluteString, "http://100.118.255.23:8080")
        XCTAssertEqual(TodoHubClient.baseURL(from: " https://pi.ts.net/api/ ")?.absoluteString, "https://pi.ts.net")
        XCTAssertNil(TodoHubClient.baseURL(from: ""))
        XCTAssertNil(TodoHubClient.baseURL(from: "ftp://pi"))
    }

    func testWebSocketURL() {
        let base = URL(string: "http://pi:8080")!
        XCTAssertEqual(TodoHubEvents.webSocketURL(baseURL: base, token: "a b")?.absoluteString, "ws://pi:8080/api/ws?token=a%20b")
        XCTAssertEqual(
            TodoHubEvents.webSocketURL(baseURL: URL(string: "https://pi.ts.net")!, token: nil)?.absoluteString,
            "wss://pi.ts.net/api/ws"
        )
    }

    func testCacheRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-hub-cache-\(UUID().uuidString)/cache.json")
        let cache = TodoHubCache(fileURL: url)
        XCTAssertNil(cache.load())
        let snapshot = TodoHubSnapshot(
            todos: [Todo(id: "a", section: .si, title: "x", conversationStatus: .idle)],
            conversations: [],
            savedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try cache.save(snapshot)
        XCTAssertEqual(cache.load(), snapshot)
    }

    /// Opt-in end-to-end check against a real todo-server:
    /// `TODO_HUB_LIVE_URL=http://127.0.0.1:18095 TODO_HUB_LIVE_TOKEN=… swift test --filter Live`
    func testLiveServerRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TODO_HUB_LIVE_URL"], let url = TodoHubClient.baseURL(from: raw) else {
            throw XCTSkip("Set TODO_HUB_LIVE_URL to run against a live todo-server")
        }
        let client = TodoHubClient(baseURL: url, token: env["TODO_HUB_LIVE_TOKEN"])
        try await client.health()
        let computer = try await client.createComputer(
            CreateComputerRequest(name: "Live", hostname: "live.tailnet", username: "me")
        )
        _ = try await client.setSectionComputer(.si, SetSectionComputerRequest(computerId: computer.id, cwd: "~/live"))
        let todo = try await client.createTodo(CreateTodoRequest(section: .si, title: "live test"))
        let opened = try await client.openConversation(todoId: todo.id)
        XCTAssertEqual(opened.computer.id, computer.id)
        XCTAssertEqual(opened.cwd, "~/live")
        XCTAssertTrue(opened.tmuxName.hasPrefix("ai/claude/todo-"))
        let listed = try await client.listTodos()
        XCTAssertEqual(listed.first { $0.id == todo.id }?.conversationStatus, .unknown)
        let closed = try await client.closeConversation(todoId: todo.id)
        XCTAssertEqual(closed.status, .closed)
        let fetched = try await client.conversation(todoId: todo.id)
        XCTAssertEqual(fetched?.sessionId, opened.sessionId)
        try await client.deleteTodo(id: todo.id)
        let afterDelete = try await client.conversation(todoId: todo.id)
        XCTAssertNil(afterDelete)
        try await client.clearSectionComputer(.si)
        try await client.deleteComputer(id: computer.id)
        if client.token != nil {
            await XCTAssertThrowsHubError(
                try await TodoHubClient(baseURL: url, token: nil).listTodos(), .unauthorized
            )
        }
    }

    func testLiveServerEvents() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TODO_HUB_LIVE_URL"], let url = TodoHubClient.baseURL(from: raw) else {
            throw XCTSkip("Set TODO_HUB_LIVE_URL to run against a live todo-server")
        }
        let client = TodoHubClient(baseURL: url, token: env["TODO_HUB_LIVE_TOKEN"])
        let received = expectation(description: "refresh event")
        let listener = Task {
            for await _ in TodoHubEvents.refreshes(baseURL: url, token: client.token) {
                received.fulfill()
                return
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000) // let the socket connect
        let todo = try await client.createTodo(CreateTodoRequest(section: .p, title: "event test"))
        await fulfillment(of: [received], timeout: 5)
        listener.cancel()
        try await client.deleteTodo(id: todo.id)
    }

    func testTodoConversationCommands() {
        let open = TmuxCommandBuilder.openTodoConversation(
            tmuxName: "ai/claude/todo-4f3ff5fa", cwd: "~/it's here", sessionId: "20218a19"
        )
        XCTAssertTrue(open.hasPrefix("export PATH="))
        XCTAssertTrue(open.hasSuffix(
            #"exec "$HOME/.ai-remote/bin/ai-todo-open" 'ai/claude/todo-4f3ff5fa' '~/it'"'"'s here' '20218a19'"#
        ))
        XCTAssertTrue(TmuxCommandBuilder.killSessionExact(tmuxName: "ai/claude/todo-1").hasSuffix(
            "tmux kill-session -t '=ai/claude/todo-1'"
        ))
    }
}

private func XCTAssertThrowsHubError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ expected: TodoHubError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as TodoHubError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error \(error)", file: file, line: line)
    }
}
