import XCTest
@testable import AISessionCore

/// Projects, sessions, memories and weekly stats: decoding of the spec's JSON samples and the
/// exact requests the client sends (through `StubURLProtocol` from `TodoHubClientTests`).
final class ProjectsClientTests: XCTestCase {
    static let computerJSON = """
    {"id":"c1","name":"spreads-macbook-pro","hostname":"spread.tailnet","port":22,"username":"me","created_at":"2026-10-15 20:17:27","updated_at":"2026-10-15 20:17:27"}
    """

    static let projectJSON = """
    {"id":"p1","name":"sigma-revenue","section":"Si","computer":\(computerJSON),"folder":"~/programming/sigma-revenue",
     "repo_url":null,"digest_enabled":true,"created_at":"2026-10-16 08:00:00","updated_at":"2026-10-16 08:00:00",
     "open_todos":3,"sessions":41,"memories":57,"last_activity":"2026-10-16T09:12:03Z"}
    """

    static let suggestionJSON = """
    [{"computer":\(computerJSON),"folder":"~/programming/sigma-revenue","name":"sigma-revenue","repo_url":null,
      "sessions":19,"last_activity":"2026-10-16T09:12:03Z","example_cwds":["~/programming/sigma-revenue/sigma-revenue-backend"]}]
    """

    static let memoryJSON = """
    {"id":"m1","project_id":"p1","todo_id":null,"computer_id":"c1","tool":"claude","session_id":"s1",
     "kind":"gotcha","text":"Deploys wait for the main build.","files":["deploy/pi/todo-update.sh"],"confidence":0.8,
     "source":"extracted","pinned":false,"archived":false,"created_at":"2026-10-16 09:00:00","updated_at":"2026-10-16 09:00:00"}
    """

    static let manualMemoryJSON = """
    {"id":"m2","project_id":"p1","todo_id":"t1","computer_id":null,"tool":null,"session_id":null,
     "kind":"open_thread","text":"Decide on tracked AGENTS.md files.","files":[],"confidence":null,
     "source":"manual","pinned":true,"archived":false,"created_at":"2026-10-16 10:00:00","updated_at":"2026-10-16 10:00:00"}
    """

    static let sessionJSON = """
    {"tool":"claude","session_id":"s1","computer_id":"c1","cwd":"~/programming/todo-app","title":"Add projects",
     "repo_root":"~/programming/todo-app","repo_url":"git@github.com:tsetsoo/todo-app.git","project_id":"p1",
     "project_override":false,"prompts":12,"assistant_turns":12,"input_tokens":4021,"output_tokens":51234,
     "cache_read_tokens":9123456,"cache_creation_tokens":402311,"active_seconds":5400,
     "first_activity":"2026-10-16T07:01:12Z","last_activity":"2026-10-16T09:12:03Z",
     "files_touched":["crates/todo-server/src/db.rs"],"models":["claude-opus-5-5"],
     "stats_updated_at":"2026-10-16T09:15:00Z","created_at":"2026-10-16 07:05:00","todo_id":"t1","status":"waiting"}
    """

    /// A bare session (created by a memories upload): nulls everywhere, no todo link.
    static let bareSessionJSON = """
    {"tool":"codex","session_id":"s2","computer_id":"c1","cwd":"~/x","title":null,"repo_root":null,"repo_url":null,
     "project_id":null,"project_override":1,"prompts":0,"assistant_turns":0,"input_tokens":null,"output_tokens":null,
     "cache_read_tokens":null,"cache_creation_tokens":null,"active_seconds":0,"first_activity":null,"last_activity":null,
     "files_touched":[],"models":[],"stats_updated_at":null,"created_at":"2026-10-16 07:05:00"}
    """

    static let weeklyJSON = """
    {"week_start":"2026-10-12","week_end":"2026-10-18",
     "totals":{"sessions":23,"prompts":180,"assistant_turns":176,"input_tokens":1000,"output_tokens":2000,
               "cache_read_tokens":30000,"cache_creation_tokens":null,"active_seconds":61200,"files_touched":88},
     "by_project":[{"project_id":"p1","name":"todo-app","sessions":20,"prompts":170,"assistant_turns":166,
                    "input_tokens":1000,"output_tokens":2000,"cache_read_tokens":30000,"cache_creation_tokens":null,
                    "active_seconds":60000,"files_touched":80},
                   {"project_id":null,"name":null,"sessions":3,"prompts":10,"assistant_turns":10,"input_tokens":null,
                    "output_tokens":null,"cache_read_tokens":null,"cache_creation_tokens":null,"active_seconds":1200,
                    "files_touched":8}],
     "by_section":[{"section":"Sp","sessions":1,"prompts":1,"assistant_turns":1,"input_tokens":null,"output_tokens":null,
                    "cache_read_tokens":null,"cache_creation_tokens":null,"active_seconds":60,"files_touched":0},
                   {"section":null,"sessions":22,"prompts":179,"assistant_turns":175,"input_tokens":1000,"output_tokens":2000,
                    "cache_read_tokens":30000,"cache_creation_tokens":null,"active_seconds":61140,"files_touched":88}],
     "by_computer":[{"computer_id":"c1","name":"spreads-macbook-pro","sessions":23,"prompts":180,"assistant_turns":176,
                     "input_tokens":1000,"output_tokens":2000,"cache_read_tokens":30000,"cache_creation_tokens":null,
                     "active_seconds":61200,"files_touched":88}]}
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
        let data = try XCTUnwrap(lastRequest.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func queryItems() -> [String: String] {
        let items = URLComponents(url: lastRequest.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    private func respond(_ body: String, status: Int = 200) {
        StubURLProtocol.handler = { _ in .init(status: status, body: body) }
    }

    // MARK: Decoding

    func testDecodesTodoWithAndWithoutProjectId() throws {
        let json = """
        [{"id":"t1","section":"I","title":"a","completed":false,"importance":"medium","created_at":"x","updated_at":"x","project_id":"p1"},
         {"id":"t2","section":"Sp","title":"b","completed":false,"importance":"medium","created_at":"x","updated_at":"x"}]
        """
        let todos = try TodoHubClient.makeDecoder().decode([Todo].self, from: Data(json.utf8))
        XCTAssertEqual(todos[0].projectId, "p1")
        XCTAssertNil(todos[1].projectId)

        let conversation = try TodoHubClient.makeDecoder().decode(
            Conversation.self, from: Data(TodoHubClientTests.conversationJSON.utf8)
        )
        XCTAssertNil(conversation.projectId)
        let withProject = String(TodoHubClientTests.conversationJSON.dropLast()) + #","project_id":"p1"}"#
        XCTAssertEqual(
            try TodoHubClient.makeDecoder().decode(Conversation.self, from: Data(withProject.utf8)).projectId, "p1"
        )
    }

    func testDecodesProjectMemorySessionWeekly() throws {
        let decoder = TodoHubClient.makeDecoder()
        let project = try decoder.decode(Project.self, from: Data(Self.projectJSON.utf8))
        XCTAssertEqual(project.name, "sigma-revenue")
        XCTAssertEqual(project.section, .si)
        XCTAssertEqual(project.computer.name, "spreads-macbook-pro")
        XCTAssertNil(project.repoUrl)
        XCTAssertTrue(project.digestEnabled)
        XCTAssertEqual(project.openTodos, 3)
        XCTAssertEqual(project.sessions, 41)
        XCTAssertEqual(project.memories, 57)
        XCTAssertEqual(project.lastActivity, "2026-10-16T09:12:03Z")
        XCTAssertNotNil(project.lastActivityDate)

        // Counts are optional on the wire (e.g. a minimal create response).
        let minimal = """
        {"id":"p2","name":"x","section":"Si","computer":\(Self.computerJSON),"folder":"~/x","digest_enabled":false,"created_at":"","updated_at":""}
        """
        let bare = try decoder.decode(Project.self, from: Data(minimal.utf8))
        XCTAssertEqual(bare.openTodos, 0)
        XCTAssertNil(bare.lastActivity)
        XCTAssertFalse(bare.digestEnabled)

        let suggestions = try decoder.decode([ProjectSuggestion].self, from: Data(Self.suggestionJSON.utf8))
        XCTAssertEqual(suggestions.first?.folder, "~/programming/sigma-revenue")
        XCTAssertEqual(suggestions.first?.sessions, 19)
        XCTAssertEqual(suggestions.first?.exampleCwds, ["~/programming/sigma-revenue/sigma-revenue-backend"])
        XCTAssertEqual(suggestions.first?.id, "c1|~/programming/sigma-revenue")

        let memory = try decoder.decode(Memory.self, from: Data(Self.memoryJSON.utf8))
        XCTAssertEqual(memory.kind, .gotcha)
        XCTAssertEqual(memory.files, ["deploy/pi/todo-update.sh"])
        XCTAssertEqual(memory.confidence, 0.8)
        XCTAssertFalse(memory.isManual)
        let manual = try decoder.decode(Memory.self, from: Data(Self.manualMemoryJSON.utf8))
        XCTAssertEqual(manual.kind, .openThread)
        XCTAssertNil(manual.sessionId)
        XCTAssertNil(manual.confidence)
        XCTAssertTrue(manual.isManual)
        XCTAssertTrue(manual.pinned)
        XCTAssertNotNil(manual.createdDate)

        let session = try decoder.decode(HubSession.self, from: Data(Self.sessionJSON.utf8))
        XCTAssertEqual(session.id, "claude/s1")
        XCTAssertEqual(session.todoId, "t1")
        XCTAssertEqual(session.status, .waiting)
        XCTAssertFalse(session.projectOverride)
        XCTAssertEqual(session.stats.prompts, 12)
        XCTAssertEqual(session.stats.outputTokens, 51234)
        XCTAssertEqual(session.stats.filesTouched, ["crates/todo-server/src/db.rs"])
        XCTAssertEqual(session.stats.models, ["claude-opus-5-5"])
        let bareSession = try decoder.decode(HubSession.self, from: Data(Self.bareSessionJSON.utf8))
        XCTAssertNil(bareSession.title)
        XCTAssertNil(bareSession.todoId)
        XCTAssertNil(bareSession.status)
        XCTAssertTrue(bareSession.projectOverride, "integer 1 decodes as an override")
        XCTAssertNil(bareSession.stats.inputTokens)
        XCTAssertNil(bareSession.stats.lastActivity)

        // Stats nested under "stats" (the upload shape) decode too.
        let nested = """
        {"tool":"claude","session_id":"s3","computer_id":"c1","cwd":"~/x","created_at":"",
         "stats":{"prompts":2,"assistant_turns":1,"active_seconds":30,"files_touched":["a"],"models":[]}}
        """
        let nestedSession = try decoder.decode(HubSession.self, from: Data(nested.utf8))
        XCTAssertEqual(nestedSession.stats.prompts, 2)
        XCTAssertEqual(nestedSession.stats.filesTouched, ["a"])

        let weekly = try decoder.decode(WeeklyStats.self, from: Data(Self.weeklyJSON.utf8))
        XCTAssertEqual(weekly.weekStart, "2026-10-12")
        XCTAssertEqual(weekly.weekEnd, "2026-10-18")
        XCTAssertEqual(weekly.totals.sessions, 23)
        XCTAssertNil(weekly.totals.cacheCreationTokens)
        XCTAssertEqual(weekly.totals.totalTokens, 33000)
        XCTAssertEqual(weekly.byProject.count, 2)
        XCTAssertEqual(weekly.byProject[0].projectId, "p1")
        XCTAssertEqual(weekly.byProject[0].counters.activeSeconds, 60000)
        XCTAssertNil(weekly.byProject[1].projectId)
        XCTAssertNil(weekly.byProject[1].counters.totalTokens, "all-null tokens stay null")
        XCTAssertEqual(weekly.bySection[0].section, .sp)
        XCTAssertNil(weekly.bySection[1].section)
        XCTAssertEqual(weekly.byComputer[0].name, "spreads-macbook-pro")
    }

    func testOldCacheFileWithoutProjectsLoads() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-hub-cache-\(UUID().uuidString)/cache.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written by the previous app version: no "projects", no "projectId".
        let old = """
        {"todos":[{"id":"a","section":"Si","title":"x","completed":false,"importance":"medium","createdAt":"","updatedAt":""}],
         "conversations":[],"savedAt":"2026-10-15T10:00:00Z"}
        """
        try Data(old.utf8).write(to: url)
        let snapshot = try XCTUnwrap(TodoHubCache(fileURL: url).load())
        XCTAssertEqual(snapshot.todos.first?.id, "a")
        XCTAssertNil(snapshot.todos.first?.projectId)
        XCTAssertEqual(snapshot.projects, [])

        let project = try TodoHubClient.makeDecoder().decode(Project.self, from: Data(Self.projectJSON.utf8))
        let fresh = TodoHubSnapshot(todos: [], conversations: [], projects: [project], savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try TodoHubCache(fileURL: url).save(fresh)
        XCTAssertEqual(TodoHubCache(fileURL: url).load(), fresh)
    }

    // MARK: Todos

    func testListTodosByProject() async throws {
        respond("[]")
        _ = try await client().listTodos(projectId: "p1")
        XCTAssertEqual(lastRequest.url?.path, "/api/todos")
        XCTAssertEqual(lastRequest.url?.query, "project_id=p1")
        _ = try await client().listTodos(section: .i)
        XCTAssertEqual(lastRequest.url?.query, "section=I")
    }

    func testUpdateTodoClearEncodesExplicitNull() async throws {
        let todo = #"{"id":"t1","section":"I","title":"a","completed":false,"importance":"medium","created_at":"","updated_at":""}"#
        respond(todo)
        _ = try await client().updateTodo(id: "t1", UpdateTodoRequest(projectId: .clear))
        let raw = String(data: try XCTUnwrap(lastRequest.httpBody), encoding: .utf8)
        XCTAssertEqual(raw, #"{"project_id":null}"#)

        _ = try await client().updateTodo(id: "t1", UpdateTodoRequest(projectId: .set("p1")))
        XCTAssertEqual(try lastBody()["project_id"] as? String, "p1")

        _ = try await client().updateTodo(id: "t1", UpdateTodoRequest(title: "b"))
        let body = try lastBody()
        XCTAssertEqual(body["title"] as? String, "b")
        XCTAssertFalse(body.keys.contains("project_id"), "unchanged project is absent")
    }

    func testCreateTodoWithProject() async throws {
        respond(#"{"id":"t1","section":"I","title":"a","completed":false,"importance":"medium","created_at":"","updated_at":"","project_id":"p1"}"#)
        let todo = try await client().createTodo(CreateTodoRequest(title: "a", projectId: "p1"))
        XCTAssertEqual(todo.projectId, "p1")
        let body = try lastBody()
        XCTAssertEqual(body["project_id"] as? String, "p1")
        XCTAssertFalse(body.keys.contains("section"))
    }

    // MARK: Projects

    func testProjectEndpoints() async throws {
        respond("[\(Self.projectJSON)]")
        let projects = try await client().listProjects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(lastRequest.httpMethod, "GET")
        XCTAssertEqual(lastRequest.url?.path, "/api/projects")

        respond(Self.projectJSON)
        _ = try await client().project(id: "p1")
        XCTAssertEqual(lastRequest.url?.path, "/api/projects/p1")

        respond(Self.projectJSON, status: 201)
        _ = try await client().createProject(CreateProjectRequest(
            name: "sigma-revenue", section: .si, folder: "~/programming/sigma-revenue"
        ))
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        XCTAssertEqual(lastRequest.url?.path, "/api/projects")
        var body = try lastBody()
        XCTAssertEqual(body["name"] as? String, "sigma-revenue")
        XCTAssertEqual(body["section"] as? String, "Si")
        XCTAssertFalse(body.keys.contains("computer_id"))
        XCTAssertEqual(body["folder"] as? String, "~/programming/sigma-revenue")
        XCTAssertFalse(body.keys.contains("repo_url"))
        XCTAssertFalse(body.keys.contains("digest_enabled"))

        respond(Self.projectJSON)
        _ = try await client().updateProject(id: "p1", UpdateProjectRequest(repoUrl: .clear, digestEnabled: false))
        XCTAssertEqual(lastRequest.httpMethod, "PATCH")
        XCTAssertEqual(lastRequest.url?.path, "/api/projects/p1")
        body = try lastBody()
        XCTAssertTrue(body["repo_url"] is NSNull)
        XCTAssertEqual(body["digest_enabled"] as? Bool, false)
        XCTAssertFalse(body.keys.contains("name"))
        XCTAssertFalse(body.keys.contains("folder"))

        _ = try await client().updateProject(id: "p1", UpdateProjectRequest(name: "n", folder: "~/f", repoUrl: .set("git@x:y.git")))
        body = try lastBody()
        XCTAssertEqual(body["name"] as? String, "n")
        XCTAssertEqual(body["folder"] as? String, "~/f")
        XCTAssertEqual(body["repo_url"] as? String, "git@x:y.git")
        XCTAssertFalse(body.keys.contains("digest_enabled"))

        respond(#"{"deleted":"p1"}"#)
        try await client().deleteProject(id: "p1")
        XCTAssertEqual(lastRequest.httpMethod, "DELETE")
        XCTAssertEqual(lastRequest.url?.path, "/api/projects/p1")

        respond(Self.suggestionJSON)
        let suggestions = try await client().projectSuggestions()
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(lastRequest.url?.path, "/api/projects/suggestions")
    }

    func testProjectNestingConflictKeepsServerMessage() async {
        respond(#"{"error":"Folder is inside project sigma-revenue"}"#, status: 409)
        do {
            _ = try await client().createProject(CreateProjectRequest(name: "x", section: .si, folder: "~/a/b"))
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(error as? TodoHubError, .conflict("Folder is inside project sigma-revenue"))
        }
    }

    // MARK: Sessions and stats

    func testListSessionsQuery() async throws {
        respond("[\(Self.sessionJSON),\(Self.bareSessionJSON)]")
        let sessions = try await client().listSessions(projectId: "p1", computerId: "c1", since: "2026-10-01", limit: 50)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(lastRequest.url?.path, "/api/sessions")
        XCTAssertEqual(queryItems(), ["project_id": "p1", "computer_id": "c1", "since": "2026-10-01", "limit": "50"])

        _ = try await client().listSessions()
        XCTAssertNil(lastRequest.url?.query)
    }

    func testSetSessionProjectBodies() async throws {
        respond("{}")
        try await client().setSessionProject(tool: "claude", sessionId: "s/1", projectId: "p1")
        XCTAssertEqual(lastRequest.httpMethod, "PUT")
        XCTAssertEqual(lastRequest.url?.absoluteString, "http://pi.tailnet:8080/api/sessions/claude/s%2F1/project")
        XCTAssertEqual(String(data: try XCTUnwrap(lastRequest.httpBody), encoding: .utf8), #"{"project_id":"p1"}"#)

        try await client().setSessionProject(tool: "claude", sessionId: "s1", projectId: nil)
        XCTAssertEqual(String(data: try XCTUnwrap(lastRequest.httpBody), encoding: .utf8), #"{"project_id":null}"#)
    }

    func testSetSessionProjectAutoBody() async throws {
        respond("{}")
        try await client().setSessionProjectAuto(tool: "codex", sessionId: "s2")
        XCTAssertEqual(lastRequest.httpMethod, "PUT")
        XCTAssertEqual(lastRequest.url?.path, "/api/sessions/codex/s2/project")
        XCTAssertEqual(String(data: try XCTUnwrap(lastRequest.httpBody), encoding: .utf8), #"{"auto":true}"#)
    }

    func testWeeklyStatsQuery() async throws {
        respond(Self.weeklyJSON)
        let weekly = try await client().weeklyStats(weekStart: "2026-10-12", projectId: "p1")
        XCTAssertEqual(weekly.totals.prompts, 180)
        XCTAssertEqual(lastRequest.url?.path, "/api/stats/weekly")
        XCTAssertEqual(queryItems(), ["week_start": "2026-10-12", "project_id": "p1"])

        _ = try await client().weeklyStats(weekStart: nil, projectId: nil)
        XCTAssertNil(lastRequest.url?.query)
    }

    // MARK: Memories

    func testMemoriesQueryKinds() async throws {
        respond("[\(Self.memoryJSON),\(Self.manualMemoryJSON)]")
        let memories = try await client().listMemories(MemoryQuery(
            projectId: "p1", kinds: [.gotcha, .decision], includeArchived: true, limit: 1000
        ))
        XCTAssertEqual(memories.count, 2)
        XCTAssertEqual(lastRequest.url?.path, "/api/memories")
        XCTAssertEqual(queryItems(), ["project_id": "p1", "kind": "gotcha,decision", "include_archived": "true", "limit": "1000"])

        _ = try await client().listMemories(MemoryQuery(
            todoId: "t1", since: "2026-10-01", tool: "claude", sessionId: "s1", pinned: true
        ))
        XCTAssertEqual(queryItems(), ["todo_id": "t1", "since": "2026-10-01", "tool": "claude", "session_id": "s1", "pinned": "true"])

        _ = try await client().listMemories(MemoryQuery())
        XCTAssertNil(lastRequest.url?.query)
    }

    func testCreateMemoryBody() async throws {
        respond(Self.manualMemoryJSON, status: 201)
        let memory = try await client().createMemory(CreateMemoryRequest(
            kind: .openThread, text: "Decide on tracked AGENTS.md files.", projectId: "p1", pinned: true
        ))
        XCTAssertEqual(memory.id, "m2")
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        XCTAssertEqual(lastRequest.url?.path, "/api/memories")
        let body = try lastBody()
        XCTAssertEqual(body["kind"] as? String, "open_thread")
        XCTAssertEqual(body["text"] as? String, "Decide on tracked AGENTS.md files.")
        XCTAssertEqual(body["project_id"] as? String, "p1")
        XCTAssertEqual(body["pinned"] as? Bool, true)
        XCTAssertFalse(body.keys.contains("todo_id"))
        XCTAssertFalse(body.keys.contains("files"))
    }

    func testUpdateAndDeleteMemory() async throws {
        respond(Self.memoryJSON)
        _ = try await client().updateMemory(id: "m1", UpdateMemoryRequest(pinned: true))
        XCTAssertEqual(lastRequest.httpMethod, "PATCH")
        XCTAssertEqual(lastRequest.url?.path, "/api/memories/m1")
        XCTAssertEqual(String(data: try XCTUnwrap(lastRequest.httpBody), encoding: .utf8), #"{"pinned":true}"#)

        _ = try await client().updateMemory(id: "m1", UpdateMemoryRequest(
            text: "t", kind: .decision, files: ["a"], archived: true, projectId: .set("p2"), todoId: .clear
        ))
        let body = try lastBody()
        XCTAssertEqual(body["text"] as? String, "t")
        XCTAssertEqual(body["kind"] as? String, "decision")
        XCTAssertEqual(body["files"] as? [String], ["a"])
        XCTAssertEqual(body["archived"] as? Bool, true)
        XCTAssertEqual(body["project_id"] as? String, "p2")
        XCTAssertTrue(body["todo_id"] is NSNull)
        XCTAssertFalse(body.keys.contains("pinned"))

        respond(#"{"deleted":"m1"}"#)
        try await client().deleteMemory(id: "m1")
        XCTAssertEqual(lastRequest.httpMethod, "DELETE")
        XCTAssertEqual(lastRequest.url?.path, "/api/memories/m1")
    }

    func testRepoWebURL() {
        XCTAssertEqual(RepoURL.web(from: "git@github.com:tsetsoo/todo-app.git")?.absoluteString, "https://github.com/tsetsoo/todo-app")
        XCTAssertEqual(RepoURL.web(from: "ssh://git@gitlab.com:22/sigma-revenue/marketing.git")?.absoluteString,
                       "https://gitlab.com/sigma-revenue/marketing")
        XCTAssertEqual(RepoURL.web(from: "https://github.com/a/b.git")?.absoluteString, "https://github.com/a/b")
        XCTAssertNil(RepoURL.web(from: nil))
        XCTAssertNil(RepoURL.web(from: "/srv/git/repo"))
    }

    func testMemoryKindLabelsAndOrder() {
        XCTAssertEqual(MemoryKind.allCases.map(\.rawValue), ["open_thread", "decision", "gotcha", "done", "files_changed"])
        XCTAssertEqual(MemoryKind.openThread.title, "Open threads")
        XCTAssertEqual(MemoryKind.filesChanged.title, "Files changed")
    }
}
