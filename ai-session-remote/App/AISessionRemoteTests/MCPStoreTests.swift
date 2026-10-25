import AISessionCore
import XCTest
@testable import AISessionRemote

@MainActor
final class MCPStoreTests: XCTestCase {
    private let mac = Computer(id: "m", name: "Mac", hostname: "mac", username: "me")

    override func setUp() {
        super.setUp()
        RecordingHub.reset()
    }

    private func makeStore() -> TodoHubStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingHub.self]
        config.urlCache = nil
        let client = TodoHubClient(
            baseURL: URL(string: "http://hub.invalid")!, token: "t", session: URLSession(configuration: config)
        )
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-store-\(UUID().uuidString).json"))
        return TodoHubStore(cache: cache, makeClient: { client })
    }

    private func conversationJSON(servers: String = "null") -> String {
        """
        {"id":"c1","todo_id":"t1","computer":{"id":"m","name":"Mac","hostname":"mac","port":22,"username":"me","created_at":"","updated_at":""},\
        "cwd":"~","tool":"claude","tmux_name":"ai/claude/todo-t1","session_id":"s1","status":"unknown",\
        "mcp_servers":\(servers)}
        """
    }

    private func bodyJSON(_ body: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
    }

    private var todo: Todo { Todo(id: "t1", section: .si, title: "x") }

    func testOpenSendsTheSelection() async throws {
        RecordingHub.respond("POST", "/api/todos/t1/conversation", conversationJSON(servers: #"["grafana"]"#))
        let opened = try await makeStore().openConversation(
            for: todo, tool: "claude", config: nil, mcpServers: ["grafana"]
        )
        XCTAssertEqual(opened.mcpServers, ["grafana"])
        let request = try XCTUnwrap(RecordingHub.requests.first { $0.path == "/api/todos/t1/conversation" })
        XCTAssertEqual(try bodyJSON(request.body)["mcp_servers"] as? [String], ["grafana"])
    }

    func testSetServersNilSendsNullAndStoresTheResult() async throws {
        RecordingHub.respond("PUT", "/api/conversations/c1/mcp", conversationJSON())
        let store = makeStore()
        let conversation = try JSONDecoder.snake.decode(Conversation.self, from: Data(conversationJSON(servers: #"["a"]"#).utf8))
        try await store.setServers(nil, for: conversation)
        let request = try XCTUnwrap(RecordingHub.requests.first { $0.path == "/api/conversations/c1/mcp" })
        let json = try bodyJSON(request.body)
        XCTAssertTrue(json["mcp_servers"] is NSNull)
        XCTAssertNil(store.conversations["c1"]?.mcpServers)
    }

    func testSetDefaultServersMapsNilToClear() async throws {
        RecordingHub.respond("PATCH", "/api/computers/m", #"{"id":"m","name":"Mac","hostname":"mac","port":22,"username":"me","created_at":"","updated_at":""}"#)
        let store = makeStore()
        try await store.setDefaultServers(nil, for: mac)
        let request = try XCTUnwrap(RecordingHub.requests.first { $0.path == "/api/computers/m" })
        XCTAssertTrue(try bodyJSON(request.body)["mcp_default"] is NSNull)
        XCTAssertEqual(store.computers.map(\.id), ["m"])
    }

    func testSetDefaultServersForProjectSendsTheList() async throws {
        RecordingHub.respond("PATCH", "/api/projects/p1", #"{"id":"p1","name":"P","computer":{"id":"m","name":"Mac","hostname":"mac","port":22,"username":"me","created_at":"","updated_at":""},"folder":"~/p","section":"Si","mcp_default":["a","b"]}"#)
        let store = makeStore()
        let project = Project(id: "p1", name: "P", computer: mac, folder: "~/p")
        try await store.setDefaultServers(["a", "b"], for: project)
        let request = try XCTUnwrap(RecordingHub.requests.first { $0.path == "/api/projects/p1" })
        XCTAssertEqual(try bodyJSON(request.body)["mcp_default"] as? [String], ["a", "b"])
        XCTAssertEqual(store.project(id: "p1")?.mcpDefault, ["a", "b"])
    }

    func testListingExit127MeansNoList() throws {
        let missing = SSHExecResult(exitCode: 127, stdout: "", stderr: "not found")
        XCTAssertNil(try RemoteConversations.mcpServers(from: missing, computerName: "Mac"))
        let ok = SSHExecResult(exitCode: 0, stdout: #"[{"name":"grafana","summary":"x"}]"#, stderr: "")
        XCTAssertEqual(try RemoteConversations.mcpServers(from: ok, computerName: "Mac")?.map(\.name), ["grafana"])
        let failed = SSHExecResult(exitCode: 2, stdout: "", stderr: "boom")
        XCTAssertThrowsError(try RemoteConversations.mcpServers(from: failed, computerName: "Mac"))
        let garbled = SSHExecResult(exitCode: 0, stdout: "nope", stderr: "")
        XCTAssertThrowsError(try RemoteConversations.mcpServers(from: garbled, computerName: "Mac"))
    }

    func testHasMCPListIsUnknownUntilListed() {
        XCTAssertNil(makeStore().hasMCPList(mac))
    }

    func testClaudeForkCarriesTheSourceServers() {
        let created = Conversation(
            id: "n", todoId: "t1", computer: mac, cwd: "~", tool: "claude", tmuxName: "ai/claude/todo-t1-2",
            sessionId: "minted", status: .unknown, mcpServers: ["grafana"]
        )
        let command = TodoHubStore.forkCommand(created, arguments: ["claude", "--resume", "src", "--fork-session"])
        XCTAssertTrue(command.contains("launch-args claude 'grafana'"), command)
        let plain = Conversation(
            id: "n", todoId: "t1", computer: mac, cwd: "~", tool: "claude", tmuxName: "x",
            sessionId: "minted", status: .unknown
        )
        XCTAssertFalse(TodoHubStore.forkCommand(plain, arguments: ["claude"]).contains("launch-args"))
    }
}

private extension JSONDecoder {
    static var snake: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// Answers hub calls with canned bodies and records what was sent.
private final class RecordingHub: URLProtocol, @unchecked Sendable {
    struct Recorded { let method: String; let path: String; let body: Data? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) private static var responses: [String: String] = [:]

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock(); recorded = []; responses = [:]; lock.unlock()
    }

    static func respond(_ method: String, _ path: String, _ body: String) {
        lock.lock(); responses["\(method) \(path)"] = body; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        Self.lock.lock()
        Self.recorded.append(Recorded(method: method, path: path, body: body))
        let canned = Self.responses["\(method) \(path)"]
        Self.lock.unlock()
        let status = canned == nil ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [
            "Content-Type": "application/json"
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((canned ?? #"{"error":"missing"}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
