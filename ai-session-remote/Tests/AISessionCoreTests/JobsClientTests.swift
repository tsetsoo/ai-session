@testable import AISessionCore
import XCTest

/// Scheduler jobs: decoding of the hub's JSON and the exact requests the client sends.
final class JobsClientTests: XCTestCase {
    static let conversationJobJSON = """
    {"id":"j1","name":"Research","enabled":true,"trigger":{"kind":"cron","cron":"0 8 * * *"},
     "action":{"kind":"conversation","project_id":"p","computer_id":null,"tool":"claude","folder":null,"prompt":"x",
               "priority":"background","limit":{"mode":"wait","five_hour":40,"weekly":null}},
     "max_runs_per_day":4,"created_at":"2026-11-02 08:00:00","updated_at":"2026-11-02 08:00:00",
     "last_run":{"id":"r1","job_id":"j1","due_at":"2026-11-02 07:00:00","state":"waiting","computer_id":"mac","todo_id":null,
                 "waiting_reason":"5h 72% > 60%","result":null,"started_at":null,"created_at":"x","updated_at":"x"},
     "next_fire_at":"2026-11-03T06:00:00Z"}
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

    private func respond(_ body: String, status: Int = 200) {
        StubURLProtocol.handler = { _ in .init(status: status, body: body) }
    }

    func testJobDecodesConversationAction() throws {
        let job = try TodoHubClient.makeDecoder().decode(SchedulerJob.self, from: Data(Self.conversationJobJSON.utf8))
        XCTAssertEqual(job.trigger, .cron("0 8 * * *"))
        guard case let .conversation(action) = job.action else { return XCTFail("\(job.action)") }
        XCTAssertEqual(action.projectId, "p")
        XCTAssertNil(action.computerId)
        XCTAssertEqual(action.priority, .background)
        XCTAssertEqual(action.limit, .wait(fiveHour: 40, weekly: nil))
        XCTAssertEqual(job.maxRunsPerDay, 4)
        XCTAssertEqual(job.lastRun?.state, "waiting")
        XCTAssertEqual(job.lastRun?.waitingReason, "5h 72% > 60%")
        XCTAssertEqual(job.nextFireAt, "2026-11-03T06:00:00Z")
    }

    func testJobDecodesPushAndTodoActions() throws {
        let decoder = TodoHubClient.makeDecoder()
        let push = try decoder.decode(JobAction.self, from: Data(#"{"kind":"push","title":"Stand up","body":"Stretch"}"#.utf8))
        XCTAssertEqual(push, .push(title: "Stand up", body: "Stretch"))
        let todo = try decoder.decode(JobAction.self, from: Data(#"{"kind":"todo","title":"Review","project_id":null,"section":"Si"}"#.utf8))
        XCTAssertEqual(todo, .todo(title: "Review", projectId: nil, section: "Si"))
        XCTAssertEqual(try decoder.decode(JobTrigger.self, from: Data(#"{"kind":"manual"}"#.utf8)), .manual)
        XCTAssertEqual(try decoder.decode(LimitSetting.self, from: Data(#"{"mode":"always"}"#.utf8)), .always)
    }

    func testCreateJobBody() async throws {
        respond(Self.conversationJobJSON, status: 201)
        let action = ConversationJobAction(projectId: "p", computerId: nil, tool: "claude", folder: nil, prompt: "x",
                                           priority: .urgent, limit: .wait(fiveHour: nil, weekly: 70))
        _ = try await client().createJob(CreateJobRequest(name: "R", trigger: .cron("*/5 * * * *"), action: .conversation(action)))
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        XCTAssertEqual(lastRequest.url?.path, "/api/jobs")
        let body = try lastBody()
        XCTAssertEqual(body["name"] as? String, "R")
        XCTAssertEqual(body["trigger"] as? [String: String], ["kind": "cron", "cron": "*/5 * * * *"])
        let sent = try XCTUnwrap(body["action"] as? [String: Any])
        XCTAssertEqual(sent["kind"] as? String, "conversation")
        XCTAssertEqual(sent["project_id"] as? String, "p")
        XCTAssertEqual(sent["priority"] as? String, "urgent")
        XCTAssertEqual((sent["limit"] as? [String: Any])?["mode"] as? String, "wait")
        XCTAssertEqual((sent["limit"] as? [String: Any])?["weekly"] as? Int, 70)
    }

    func testRunJobPath() async throws {
        respond(#"{"id":"r9","job_id":"j1","due_at":"x","state":"due","computer_id":null,"todo_id":null,"waiting_reason":null,"result":null,"started_at":null,"created_at":"x","updated_at":"x"}"#, status: 201)
        let run = try await client().runJob(id: "j1")
        XCTAssertEqual(run.id, "r9")
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        XCTAssertEqual(lastRequest.url?.path, "/api/jobs/j1/run")
    }

    func testSchedulerSettingsRoundTrip() async throws {
        respond(#"{"five_hour":60,"weekly":80,"pause_waiting":false}"#)
        let settings = try await client().schedulerSettings()
        XCTAssertEqual(settings, SchedulerSettings(fiveHour: 60, weekly: 80, pauseWaiting: false))
        respond(#"{"five_hour":40,"weekly":90,"pause_waiting":true}"#)
        _ = try await client().updateSchedulerSettings(SchedulerSettings(fiveHour: 40, weekly: 90, pauseWaiting: true))
        XCTAssertEqual(lastRequest.httpMethod, "PUT")
        XCTAssertEqual(lastRequest.url?.path, "/api/scheduler/settings")
        let body = try lastBody()
        XCTAssertEqual(body["five_hour"] as? Int, 40)
        XCTAssertEqual(body["pause_waiting"] as? Bool, true)
    }

    func testJobDecodesResearchAction() throws {
        let action = try TodoHubClient.makeDecoder().decode(JobAction.self, from: Data(
            #"{"kind":"research","project_id":"p","computer_id":null,"tool":"claude","folder":null,"prompt":"","priority":"background","limit":{"mode":"always"}}"#.utf8))
        guard case let .research(parts) = action else { return XCTFail("\(action)") }
        XCTAssertEqual(parts.projectId, "p")
        XCTAssertEqual(parts.limit, .always)
    }

    func testJobListSkipsUnknownActionKind() throws {
        let json = "[" + Self.conversationJobJSON + "," + Self.conversationJobJSON
            .replacingOccurrences(of: #""id":"j1""#, with: #""id":"j2""#)
            .replacingOccurrences(of: #""kind":"conversation""#, with: #""kind":"watcher""#) + "]"
        let jobs = try TodoHubClient.makeDecoder().decode([SchedulerJob].self, from: Data(json.utf8))
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs[1].action, .unsupported(kind: "watcher"))
    }

    func testTodoDecodesScheduledMarker() throws {
        let json = """
        [{"id":"t1","section":"Si","title":"Research · 2026-11-02","completed":false,"importance":"medium","created_at":"x",
          "updated_at":"x","scheduled_job_id":"j1","scheduled_run_id":"r1"},
         {"id":"t2","section":"Si","title":"plain","completed":false,"importance":"medium","created_at":"x","updated_at":"x"}]
        """
        let todos = try TodoHubClient.makeDecoder().decode([Todo].self, from: Data(json.utf8))
        XCTAssertEqual(todos[0].scheduledJobId, "j1")
        XCTAssertEqual(todos[0].scheduledRunId, "r1")
        XCTAssertNil(todos[1].scheduledJobId)
    }
}
