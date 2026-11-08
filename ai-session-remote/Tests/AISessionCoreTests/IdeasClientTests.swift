@testable import AISessionCore
import XCTest

final class IdeasClientTests: XCTestCase {
    static let ideaJSON = """
    {"id":"i1","project_id":"p","title":"Try Hermes","notes":"Compare","status":"researched","starred":true,"pending":false,
     "findings":"It works.","todo_id":"t1","run_id":"r1","source":"agent","created_at":"x","updated_at":"x"}
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

    private var lastRequest: URLRequest { StubURLProtocol.requests.last! }

    private func lastBody() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(lastRequest.httpBody)) as? [String: Any])
    }

    private func respond(_ body: String, status: Int = 200) {
        StubURLProtocol.handler = { _ in .init(status: status, body: body) }
    }

    private func queryItems() -> [String: String] {
        let items = URLComponents(url: lastRequest.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testIdeaDecodes() throws {
        let idea = try TodoHubClient.makeDecoder().decode(Idea.self, from: Data(Self.ideaJSON.utf8))
        XCTAssertEqual(idea.status, .researched)
        XCTAssertTrue(idea.starred)
        XCTAssertEqual(idea.findings, "It works.")
        XCTAssertEqual(idea.todoId, "t1")
    }

    func testListIdeasQuery() async throws {
        respond("[\(Self.ideaJSON)]")
        let ideas = try await client().listIdeas(projectId: "p", pending: true)
        XCTAssertEqual(ideas.count, 1)
        XCTAssertEqual(lastRequest.url?.path, "/api/ideas")
        XCTAssertEqual(queryItems(), ["project_id": "p", "pending": "true"])
    }

    func testUpdateIdeaBody() async throws {
        respond(Self.ideaJSON)
        _ = try await client().updateIdea(id: "i1", UpdateIdeaRequest(status: .dropped, starred: false))
        XCTAssertEqual(lastRequest.httpMethod, "PATCH")
        XCTAssertEqual(lastRequest.url?.path, "/api/ideas/i1")
        let body = try lastBody()
        XCTAssertEqual(body["status"] as? String, "dropped")
        XCTAssertEqual(body["starred"] as? Bool, false)
        XCTAssertNil(body["title"])
    }

    func testIdeaToTodoReturnsTodoId() async throws {
        respond(#"{"idea":\#(Self.ideaJSON),"todo_id":"t9"}"#, status: 201)
        let todoId = try await client().ideaToTodo(id: "i1")
        XCTAssertEqual(todoId, "t9")
        XCTAssertEqual(lastRequest.url?.path, "/api/ideas/i1/todo")
    }

    func testShapeIdeaBody() async throws {
        respond(#"{"id":"r","job_id":"j","due_at":"x","state":"due","computer_id":null,"todo_id":null,"waiting_reason":null,"result":null,"started_at":null,"created_at":"x","updated_at":"x","note":"faster startup"}"#, status: 201)
        let run = try await client().shapeIdea(projectId: "p", hint: "faster startup")
        XCTAssertEqual(run.note, "faster startup")
        XCTAssertEqual(lastRequest.url?.path, "/api/ideas/shape")
        XCTAssertEqual(try lastBody() as? [String: String], ["project_id": "p", "hint": "faster startup"])
    }

    func testIdeaEditSendsOnlyChangedFields() throws {
        var idea = try TodoHubClient.makeDecoder().decode(Idea.self, from: Data(Self.ideaJSON.utf8))
        idea.status = .new
        XCTAssertNil(IdeaEdit.request(original: idea, title: idea.title, notes: idea.notes, status: .new, starred: true == idea.starred))
        let starOnly = try XCTUnwrap(IdeaEdit.request(original: idea, title: idea.title, notes: idea.notes, status: .new, starred: false))
        XCTAssertEqual(starOnly.starred, false)
        XCTAssertNil(starOnly.status, "an unchanged status is not sent, so a research run that started meanwhile isn't undone")
        XCTAssertNil(starOnly.title)
        let dropped = try XCTUnwrap(IdeaEdit.request(original: idea, title: "  New title ", notes: idea.notes, status: .dropped, starred: true))
        XCTAssertEqual(dropped.status, .dropped)
        XCTAssertEqual(dropped.title, "New title")
    }

    func testResearchIdeaPath() async throws {
        respond(#"{"id":"r","job_id":"j","due_at":"x","state":"due","computer_id":null,"todo_id":null,"waiting_reason":null,"result":null,"started_at":null,"created_at":"x","updated_at":"x","note":"idea:i1"}"#, status: 201)
        let run = try await client().researchIdea(id: "i1")
        XCTAssertEqual(run.note, "idea:i1")
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        XCTAssertEqual(lastRequest.url?.path, "/api/ideas/i1/research")
    }

    static let runJSON = #"{"id":"r1","job_id":"j","due_at":"x","state":"due","computer_id":null,"todo_id":null,"waiting_reason":null,"result":null,"started_at":null,"created_at":"x","updated_at":"x","note":"idea:i1","group_id":"g","attempt_tool":"claude"}"#

    func testResearchSendsAttemptsAndDecodesGroup() async throws {
        respond(#"{"group_id":"g","todo_id":"t","runs":[\#(Self.runJSON)]}"#, status: 201)
        let request = ResearchRequest(computerId: "mac", attempts: [AttemptSpec(tool: "claude"), AttemptSpec(tool: "codex", model: "m")])
        let outcome = try await client().researchIdea(id: "i1", request: request)
        guard case let .group(start) = outcome else { return XCTFail("expected a group, got \(outcome)") }
        XCTAssertEqual(start.todoId, "t")
        XCTAssertEqual(start.runs.first?.groupId, "g")
        XCTAssertEqual(lastRequest.url?.path, "/api/ideas/i1/research")
        let body = try lastBody()
        XCTAssertEqual(body["computer_id"] as? String, "mac")
        let attempts = try XCTUnwrap(body["attempts"] as? [[String: String]])
        XCTAssertEqual(attempts, [["tool": "claude"], ["tool": "codex", "model": "m"]], "no model key when it is the default")
    }

    func testResearchDecodesLegacyRun() async throws {
        respond(#"{"id":"r","job_id":"j","due_at":"x","state":"due","computer_id":null,"todo_id":null,"waiting_reason":null,"result":null,"started_at":null,"created_at":"x","updated_at":"x","note":"idea:i1"}"#, status: 201)
        let outcome = try await client().researchIdea(id: "i1", request: ResearchRequest(computerId: nil, attempts: [AttemptSpec(tool: "claude")]))
        guard case let .legacy(run) = outcome else { return XCTFail("expected an older hub's run, got \(outcome)") }
        XCTAssertEqual(run.note, "idea:i1")
    }

    func testRetryRunPath() async throws {
        respond(Self.runJSON, status: 201)
        let run = try await client().retryRun(id: "r0")
        XCTAssertEqual(run.id, "r1")
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        XCTAssertEqual(lastRequest.url?.path, "/api/runs/r0/retry")
    }

    func testIdeaDecodesAttemptsAndOldIdea() throws {
        let old = try TodoHubClient.makeDecoder().decode(Idea.self, from: Data(Self.ideaJSON.utf8))
        XCTAssertEqual(old.attempts, [])
        let json = Self.ideaJSON.replacingOccurrences(of: #""updated_at":"x"}"#, with: #""updated_at":"x","attempts":[{"run_id":"r1","tool":"codex","model":"gpt-6.1","state":"failed","result":"boom","conversation_id":null,"findings":null,"chosen":false},{"run_id":"r2","tool":"claude","model":null,"state":"done","result":null,"conversation_id":"c2","findings":"B","chosen":true}]}"#)
        let idea = try TodoHubClient.makeDecoder().decode(Idea.self, from: Data(json.utf8))
        XCTAssertEqual(idea.attempts.count, 2)
        XCTAssertEqual(idea.attempts[0].model, "gpt-6.1")
        XCTAssertEqual(idea.attempts[0].result, "boom")
        XCTAssertEqual(idea.attempts[1].conversationId, "c2")
        XCTAssertTrue(idea.attempts[1].chosen)
    }

    func testComputerToolsOptional() throws {
        let base = #"{"id":"mac","name":"Mac","hostname":"mac","port":22,"username":"me","created_at":"x","updated_at":"x""#
        let without = try TodoHubClient.makeDecoder().decode(Computer.self, from: Data((base + "}").utf8))
        XCTAssertNil(without.tools)
        let with = try TodoHubClient.makeDecoder().decode(Computer.self, from: Data((base + #","tools":["claude","codex"]}"#).utf8))
        XCTAssertEqual(with.tools, ["claude", "codex"])
    }

    func testListIdeasAllProjectsHasNoProjectQuery() async throws {
        respond("[]")
        _ = try await client().listIdeas(projectId: nil)
        XCTAssertNil(lastRequest.url?.query)
    }

    func testIdeaStatusLabel() {
        XCTAssertEqual(IdeaStatus.new.label, "New")
        XCTAssertEqual(IdeaStatus.researching.label, "Researching")
        XCTAssertEqual(IdeaStatus.researched.label, "Researched")
        XCTAssertEqual(IdeaStatus.dropped.label, "Dropped")
    }
}
