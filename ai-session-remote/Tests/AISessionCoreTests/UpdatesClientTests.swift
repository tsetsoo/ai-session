@testable import AISessionCore
import XCTest

final class UpdatesClientTests: XCTestCase {
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

    private func respond(_ body: String, status: Int = 200) {
        StubURLProtocol.handler = { _ in .init(status: status, body: body) }
    }

    func testProjectUpdateDecodes() throws {
        let json = """
        {"day":"2026-11-02","text":"- done","commits":3,"conversations":2,"waiting_on":["spreads-macbook-pro"],
         "written_at":"2026-11-03 06:02:11","rewriting":true}
        """
        let update = try TodoHubClient.makeDecoder().decode(ProjectUpdate.self, from: Data(json.utf8))
        XCTAssertEqual(update.id, "2026-11-02")
        XCTAssertEqual(update.waitingOn, ["spreads-macbook-pro"])
        XCTAssertEqual(update.commits, 3)
        XCTAssertTrue(update.rewriting)
    }

    func testUpdateSummaryDecodes() throws {
        let json = """
        {"tool":"claude","session_id":"s1","todo_id":null,"title":"T","summary":"S","jira_keys":["EIN-1"],"computer":"mac"}
        """
        let summary = try TodoHubClient.makeDecoder().decode(UpdateSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.id, "claude:s1")
        XCTAssertNil(summary.todoId)
        XCTAssertEqual(summary.jiraKeys, ["EIN-1"])
    }

    func testProjectWithoutUpdateFieldsDecodes() throws {
        let json = """
        {"id":"p","name":"a","section":"Si","folder":"~/a",
         "computer":{"id":"c","name":"mac","hostname":"h","port":22,"username":"u","created_at":"","updated_at":""}}
        """
        let project = try TodoHubClient.makeDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertFalse(project.dailyUpdates)
        XCTAssertEqual(project.updateStyle, "")
    }

    func testProjectUpdatesRequest() async throws {
        respond("[]")
        _ = try await client().projectUpdates(projectId: "p", before: "2026-11-01", limit: 14)
        XCTAssertEqual(lastRequest.httpMethod, "GET")
        let url = try XCTUnwrap(lastRequest.url)
        XCTAssertEqual(url.path, "/api/projects/p/updates")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, ["before": "2026-11-01", "limit": "14"])
    }

    func testSummariesAndRewriteRequests() async throws {
        respond("[]")
        _ = try await client().updateSummaries(projectId: "p", day: "2026-11-02")
        XCTAssertEqual(lastRequest.url?.path, "/api/projects/p/updates/2026-11-02/summaries")
        respond("{\"ok\":true}")
        try await client().rewriteUpdate(projectId: "p", day: "2026-11-02")
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        XCTAssertEqual(lastRequest.url?.path, "/api/projects/p/updates/2026-11-02/rewrite")
    }

    func testUpdateProjectRequestEncodesDailyUpdates() throws {
        let data = try TodoHubClient.makeEncoder().encode(UpdateProjectRequest(dailyUpdates: true, updateStyle: "x"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["daily_updates"] as? Bool, true)
        XCTAssertEqual(object["update_style"] as? String, "x")
    }

    func testFailedCountsDecodeWithDefaults() throws {
        let decoder = TodoHubClient.makeDecoder()
        let old = try decoder.decode(ProjectUpdate.self, from: Data("""
        {"day":"2026-11-02","text":"x","commits":0,"conversations":1,"waiting_on":[],"written_at":"","rewriting":false}
        """.utf8))
        XCTAssertEqual(old.failed, 0)
        let new = try decoder.decode(ProjectUpdate.self, from: Data("""
        {"day":"2026-11-02","text":"x","commits":0,"conversations":1,"failed":2,"waiting_on":[],"written_at":"","rewriting":false}
        """.utf8))
        XCTAssertEqual(new.failed, 2)
        let summary = try decoder.decode(UpdateSummary.self, from: Data("""
        {"tool":"claude","session_id":"s","todo_id":null,"title":"T","summary":"","jira_keys":[],"computer":"mac","failed":true}
        """.utf8))
        XCTAssertTrue(summary.failed)
        let oldSummary = try decoder.decode(UpdateSummary.self, from: Data("""
        {"tool":"claude","session_id":"s","todo_id":null,"title":"T","summary":"S","jira_keys":[],"computer":"mac"}
        """.utf8))
        XCTAssertFalse(oldSummary.failed)
    }

    func testMergePagesDedupesByDay() {
        let a = ProjectUpdate(day: "2026-11-03", text: "a")
        let b = ProjectUpdate(day: "2026-11-02", text: "b")
        let c = ProjectUpdate(day: "2026-11-01", text: "c")
        XCTAssertEqual(UpdateDay.appending([a, b], [b, c]).map(\.day), ["2026-11-03", "2026-11-02", "2026-11-01"])
    }

    func testDayLabel() {
        XCTAssertEqual(UpdateDay.label("2026-11-02"), "Mon 2 Nov")
        XCTAssertEqual(UpdateDay.label("garbage"), "garbage")
    }
}
