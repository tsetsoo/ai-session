import XCTest
@testable import AISessionCore

/// Linking existing conversations to todos: hub endpoints, the `ai-todo-sessions` JSON and the
/// commands the app runs over SSH.
final class ConversationLinkingTests: XCTestCase {
    /// A conversation as the linking-capable server returns it (`session_id` plus the
    /// `claude_session_id` compatibility copy).
    static let codexConversationJSON = """
    {"todo_id":"0f3a9c21-aaaa-4bbb-8ccc-123456789abc","computer":{"id":"m1","name":"Spread","hostname":"100.94.164.63","port":22,"username":"me","created_at":"2026-10-16 10:00:00","updated_at":"2026-10-16 10:00:00"},"cwd":"~/Spread/Repository","tool":"codex","tmux_name":"ai/codex/todo-0f3a9c21","session_id":"019f8b4e-ff53-7201-8585-162b40a93fb3","claude_session_id":"019f8b4e-ff53-7201-8585-162b40a93fb3","status":"unknown","status_message":null,"status_updated_at":null,"created_at":"2026-10-16 10:00:00"}
    """

    /// `ai-todo-sessions list --json` output, exactly as the contract specifies.
    static let sessionsJSON = """
    [{"tool":"claude","session_id":"49e9880f-1111-4222-8333-444455556666","cwd":"~/Spread/Repository","title":"review https://github.com/spread-ai/data-management/pull/630","updated_at":"2026-10-16T14:53:02Z","prompts":7,"running":true,"tmux_session":"work"},
     {"tool":"codex","session_id":"019f8b4e-ff53-7201-8585-162b40a93fb3","cwd":"~/programming/sigma-revenue/sigma-revenue-webapp","title":"fix the rates screen","updated_at":"2026-07-22T19:30:38Z","prompts":3,"running":false,"tmux_session":null}]
    """

    private func client() -> TodoHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return TodoHubClient(baseURL: URL(string: "http://pi.tailnet:8080")!, token: "s3cret", session: URLSession(configuration: config))
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.requests = []
        StubURLProtocol.handler = nil
    }

    private func body(_ request: URLRequest?) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request?.httpBody))
    }

    func testDecodesSessionIdAndFallsBackToClaudeSessionId() throws {
        let decoder = TodoHubClient.makeDecoder()
        let codex = try decoder.decode(Conversation.self, from: Data(Self.codexConversationJSON.utf8))
        XCTAssertEqual(codex.tool, "codex")
        XCTAssertEqual(codex.sessionId, "019f8b4e-ff53-7201-8585-162b40a93fb3")

        // Older servers only send claude_session_id.
        let legacy = try decoder.decode(Conversation.self, from: Data(TodoHubClientTests.conversationJSON.utf8))
        XCTAssertEqual(legacy.sessionId, "20218a19-fdb7-4835-9c7f-ed31b2fd4423")
        XCTAssertEqual(legacy.tool, "claude")
    }

    /// Current servers send `claude_session_id: null` for non-Claude conversations.
    func testDecodesCodexConversationWithNullClaudeSessionId() throws {
        let json = Self.codexConversationJSON.replacingOccurrences(
            of: #""claude_session_id":"019f8b4e-ff53-7201-8585-162b40a93fb3""#,
            with: #""claude_session_id":null"#
        )
        XCTAssertTrue(json.contains(#""claude_session_id":null"#))
        let codex = try TodoHubClient.makeDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertEqual(codex.tool, "codex")
        XCTAssertEqual(codex.sessionId, "019f8b4e-ff53-7201-8585-162b40a93fb3")
    }

    func testConversationSurvivesTheOfflineCache() throws {
        let conversation = try TodoHubClient.makeDecoder()
            .decode(Conversation.self, from: Data(Self.codexConversationJSON.utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("link-cache-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = TodoHubCache(fileURL: url)
        try cache.save(TodoHubSnapshot(todos: [], conversations: [conversation]))
        XCTAssertEqual(cache.load()?.conversations, [conversation])
    }

    func testLinkConversationPostsBodyAndReplaceFlag() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: Self.codexConversationJSON) }
        let request = LinkConversationRequest(
            computerId: "m1", tool: "codex", sessionId: "019f8b4e-ff53-7201-8585-162b40a93fb3", cwd: "~/Spread/Repository"
        )
        let linked = try await client().linkConversation(todoId: "0f3a9c21-aaaa-4bbb-8ccc-123456789abc", request)
        XCTAssertEqual(linked.tmuxName, "ai/codex/todo-0f3a9c21")

        let sent = StubURLProtocol.requests.last
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(sent?.url?.path, "/api/todos/0f3a9c21-aaaa-4bbb-8ccc-123456789abc/conversation/link")
        XCTAssertNil(sent?.url?.query)
        XCTAssertEqual(try body(sent), [
            "computer_id": "m1", "tool": "codex",
            "session_id": "019f8b4e-ff53-7201-8585-162b40a93fb3", "cwd": "~/Spread/Repository",
        ])

        _ = try await client().linkConversation(todoId: "t1", request, replace: true)
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.query, "replace=true")
    }

    func testLinkConflictKeepsServerMessage() async {
        StubURLProtocol.handler = { _ in
            .init(status: 409, body: #"{"error":"That conversation is already linked to another todo"}"#)
        }
        do {
            _ = try await client().linkConversation(
                todoId: "t1", LinkConversationRequest(computerId: "m1", tool: "claude", sessionId: "s", cwd: "~")
            )
            XCTFail("expected conflict")
        } catch let error as TodoHubError {
            XCTAssertEqual(error, .conflict("That conversation is already linked to another todo"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCreateTodoFromConversation() async throws {
        let response = """
        {"todo":{"id":"0f3a9c21-aaaa-4bbb-8ccc-123456789abc","section":"Sp","title":"PR 630 review","completed":false,"importance":"medium","due_date":null,"daily_date":null,"carried_from":null,"created_at":"2026-10-16 10:00:00","updated_at":"2026-10-16 10:00:00","completed_at":null,"conversation_status":"unknown"},
         "conversation":\(Self.codexConversationJSON)}
        """
        StubURLProtocol.handler = { _ in .init(status: 201, body: response) }
        let created = try await client().createTodoFromConversation(TodoFromConversationRequest(
            section: .sp, title: "PR 630 review", projectId: "p-sp", computerId: "m1", tool: "codex",
            sessionId: "019f8b4e-ff53-7201-8585-162b40a93fb3", cwd: "~/Spread/Repository"
        ))
        XCTAssertEqual(created.todo.section, .sp)
        XCTAssertEqual(created.conversation.todoId, created.todo.id)

        let sent = StubURLProtocol.requests.last
        XCTAssertEqual(sent?.url?.path, "/api/todos/from-conversation")
        XCTAssertEqual(try body(sent)["section"], "Sp")
        XCTAssertEqual(try body(sent)["project_id"], "p-sp")
        XCTAssertEqual(try body(sent)["computer_id"], "m1")
    }

    func testDeleteConversation() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: #"{"deleted":"t1"}"#) }
        try await client().deleteConversation(todoId: "t1")
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/api/todos/t1/conversation")
    }

    func testDecodesSessionsList() throws {
        let list = try RemoteConversation.decodeList(Data(Self.sessionsJSON.utf8))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].tool, "claude")
        XCTAssertEqual(list[0].sessionId, "49e9880f-1111-4222-8333-444455556666")
        XCTAssertTrue(list[0].running)
        XCTAssertEqual(list[0].tmuxSession, "work")
        XCTAssertEqual(list[0].prompts, 7)
        XCTAssertEqual(list[0].id, "claude/49e9880f-1111-4222-8333-444455556666")
        XCTAssertNil(list[1].tmuxSession)
        XCTAssertEqual(list[1].updatedDate, ISO8601DateFormatter().date(from: "2026-07-22T19:30:38Z"))
    }

    func testRemoteCommands() {
        XCTAssertTrue(TmuxCommandBuilder.listRemoteConversations().hasSuffix(
            #""$HOME/.ai-remote/bin/ai-todo-sessions" list --json --limit 200"#
        ))
        XCTAssertTrue(TmuxCommandBuilder.deleteRemoteConversation(
            tool: "codex", sessionId: "it's", tmuxName: "ai/codex/todo-1"
        ).hasSuffix(
            #""$HOME/.ai-remote/bin/ai-todo-sessions" delete 'codex' 'it'"'"'s' --kill-tmux 'ai/codex/todo-1' --wait 10 --missing-ok"#
        ))
        XCTAssertTrue(TmuxCommandBuilder.deleteRemoteConversation(
            tool: "claude", sessionId: "s", tmuxName: "ai/claude/todo-1", waitSeconds: -3
        ).hasSuffix("--wait 0 --missing-ok"))
        // Claude keeps the 3-argument form older scripts accept; other tools pass a 4th.
        XCTAssertTrue(TmuxCommandBuilder.openTodoConversation(
            tmuxName: "ai/claude/todo-1", cwd: "~", sessionId: "s"
        ).hasSuffix(#"ai-todo-open" 'ai/claude/todo-1' '~' 's'"#))
        XCTAssertTrue(TmuxCommandBuilder.openTodoConversation(
            tmuxName: "ai/codex/todo-1", cwd: "~", sessionId: "s", tool: "codex"
        ).hasSuffix(#"ai-todo-open" 'ai/codex/todo-1' '~' 's' 'codex'"#))
    }
}
