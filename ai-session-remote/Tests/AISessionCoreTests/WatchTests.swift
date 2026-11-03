@testable import AISessionCore
import XCTest

final class WatchTests: XCTestCase {
    static func issueJSON(id: String = "i1", state: String = "open", taken: String? = nil, outcome: String? = nil) -> String {
        func q(_ v: String?) -> String { v.map { "\"\($0)\"" } ?? "null" }
        return """
        {"id":"\(id)","watcher":"sentry","key":"sentry:\(id)","job_id":"w","project_id":"ps","title":"GO-HTTP-9: boom",
         "details":"handler.go","url":"https://s/1","folder":"sigma-revenue-backend","state":"\(state)","taken_run_id":\(q(taken)),
         "todo_id":\(q(taken.map { "t-\($0)" })),"outcome":\(q(outcome)),"outcome_note":null,"resolve_error":null,
         "first_seen":"2026-11-03 07:00:00","last_seen":"2026-11-03 08:00:00","cleared_at":null,"updated_at":"x"}
        """
    }

    private func issue(state: String = "open", taken: String? = nil, outcome: String? = nil) throws -> WatchIssue {
        try TodoHubClient.makeDecoder().decode(WatchIssue.self, from: Data(Self.issueJSON(state: state, taken: taken, outcome: outcome).utf8))
    }

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

    func testWatchActionRoundTrips() throws {
        let json = #"{"kind":"watch","project_id":"ps","computer_id":"mac","watcher":"sentry","debug_tool":"claude","prompt":"Be brief."}"#
        let action = try TodoHubClient.makeDecoder().decode(JobAction.self, from: Data(json.utf8))
        guard case let .watch(watch) = action else { return XCTFail("\(action)") }
        XCTAssertEqual(watch, WatchJobAction(projectId: "ps", computerId: "mac", watcher: "sentry", debugTool: "claude", prompt: "Be brief."))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: TodoHubClient.makeEncoder().encode(action)) as? [String: Any])
        XCTAssertEqual(encoded["kind"] as? String, "watch")
        XCTAssertEqual(encoded["debug_tool"] as? String, "claude")
        XCTAssertEqual(encoded["computer_id"] as? String, "mac")
    }

    func testIssueGroupsFollowStateAndOutcome() throws {
        XCTAssertEqual(try issue().group, .waiting)
        XCTAssertEqual(try issue(taken: "r1").group, .working)
        XCTAssertEqual(try issue(taken: "r1", outcome: "needs_you").group, .needsYou)
        XCTAssertEqual(try issue(taken: "r1", outcome: "cant_fix").group, .cantFix)
        XCTAssertEqual(try issue(taken: "r1", outcome: "fixed").group, .fixed)
        XCTAssertEqual(try issue(state: "resolving", taken: "r1", outcome: "fixed").group, .resolving)
        XCTAssertEqual(try issue(taken: "r1").todoId, "t-r1")
        XCTAssertEqual(WatchIssueGroup.fixed.title, "Fixed · deploy, then resolve")
    }

    func testGroupingDropsEmptyGroupsInOrder() throws {
        let issues = [try issue(taken: "r1", outcome: "fixed"), try issue(), try issue(taken: "r2")]
        let groups = WatchIssueGrouping.grouped(issues)
        XCTAssertEqual(groups.map(\.group), [.waiting, .working, .fixed])
        XCTAssertEqual(groups.map(\.issues.count), [1, 1, 1])
    }

    func testWatchDraftRoundTripsAndNeedsComputer() {
        var draft = JobDraft.new(defaultProjectID: "ps")
        draft.kind = .watch
        draft.name = "Sigma Sentry"
        XCTAssertFalse(draft.canSave, "a watch job needs its computer")
        draft.computerId = "mac"
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.watcher, "sentry")
        XCTAssertEqual(draft.debugTool, "claude")
        guard case let .watch(action) = draft.action else { return XCTFail("\(draft.action)") }
        XCTAssertEqual(action, WatchJobAction(projectId: "ps", computerId: "mac", watcher: "sentry", debugTool: "claude", prompt: ""))
        draft.debugTool = ""
        guard case let .watch(pushOnly) = draft.action else { return XCTFail() }
        XCTAssertNil(pushOnly.debugTool)
        let job = SchedulerJob(id: "w", name: "Sigma Sentry", enabled: true, trigger: .cron("*/10 * * * *"), action: draft.action,
                               maxRunsPerDay: 4, createdAt: "x", updatedAt: "x")
        let back = JobDraft(job: job)
        XCTAssertEqual(back.kind, .watch)
        XCTAssertEqual(back.computerId, "mac")
        XCTAssertEqual(back.debugTool, "")
        XCTAssertEqual(JobDraft.watchCron, "*/10 * * * *")
    }

    func testClientListsResolvesAndRetriesWatchIssues() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: "[\(Self.issueJSON())]") }
        let issues = try await client().listWatchIssues(state: "recent")
        XCTAssertEqual(issues.first?.key, "sentry:i1")
        let url = try XCTUnwrap(StubURLProtocol.requests.last?.url)
        XCTAssertEqual(url.path, "/api/watch/issues")
        XCTAssertEqual(url.query, "state=recent")
        StubURLProtocol.handler = { _ in .init(status: 200, body: #"{"ok":true}"#) }
        try await client().resolveWatchIssue(id: "i1")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/api/watch/issues/i1/resolve")
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "POST")
        try await client().retryWatchIssue(id: "i1")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/api/watch/issues/i1/retry")
    }
}
