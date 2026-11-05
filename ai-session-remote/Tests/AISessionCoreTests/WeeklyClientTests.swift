@testable import AISessionCore
import XCTest

final class WeeklyClientTests: XCTestCase {
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

    private let fixture = """
    {"week":"2026-11-02","totals":{"commits":12,"conversations":7,"runs":5},
     "sections":[{"project_id":"p1","project_name":"Hub","headline":"Shipped the recap","wins":"- You shipped it",
       "failed":false,"rewriting":true,"commits":12,"conversations":7,"days_with_work":4,
       "days":[{"day":"2026-11-02","state":"update"},{"day":"2026-11-03","state":"quiet"}],
       "written_at":"2026-11-09 08:01:00"}],
     "jobs":{"runs":5,"done":3,"failed":1,"skipped":1,"todos_created":2,"conversations_started":1,"findings":4,
       "jobs":[{"job_id":"j1","name":"Sentry","project_name":"Hub","is_watch":true,"runs":2,"done":1,"failed":1,
         "skipped":0,"checks":6,"findings":4,
         "lines":[{"run_id":"r1","due_at":"2026-11-03 09:00:00","state":"done","outcome":"found 2","todo_id":"t1"},
                  {"run_id":"r2","due_at":"2026-11-04 09:00:00","state":"failed","outcome":"boom","todo_id":null}]}]}}
    """

    func testDecodesWeeklyRecapFromHubJSON() throws {
        let recap = try TodoHubClient.makeDecoder().decode(WeeklyRecap.self, from: Data(fixture.utf8))
        XCTAssertEqual(recap.id, "2026-11-02")
        XCTAssertEqual(recap.totals, WeeklyTotals(commits: 12, conversations: 7, runs: 5))
        let section = try XCTUnwrap(recap.sections.first)
        XCTAssertEqual(section.id, "p1")
        XCTAssertEqual(section.projectName, "Hub")
        XCTAssertEqual(section.headline, "Shipped the recap")
        XCTAssertTrue(section.rewriting)
        XCTAssertFalse(section.failed)
        XCTAssertEqual(section.daysWithWork, 4)
        XCTAssertEqual(section.days, [WeeklyDayState(day: "2026-11-02", state: "update"), WeeklyDayState(day: "2026-11-03", state: "quiet")])
        XCTAssertEqual(section.writtenAt, "2026-11-09 08:01:00")
        let jobs = try XCTUnwrap(recap.jobs)
        XCTAssertEqual(jobs.todosCreated, 2)
        XCTAssertEqual(jobs.conversationsStarted, 1)
        XCTAssertEqual(jobs.findings, 4)
        let job = try XCTUnwrap(jobs.jobs.first)
        XCTAssertEqual(job.id, "j1")
        XCTAssertTrue(job.isWatch)
        XCTAssertEqual(job.checks, 6)
        XCTAssertEqual(job.lines.map(\.id), ["r1", "r2"])
        XCTAssertEqual(job.lines[0].todoId, "t1")
        XCTAssertNil(job.lines[1].todoId)
    }

    func testDecodesNullJobsAndMissingFields() throws {
        let json = """
        {"week":"2026-11-02","totals":{"commits":0,"conversations":0,"runs":0},"sections":[],"jobs":null}
        """
        let recap = try TodoHubClient.makeDecoder().decode(WeeklyRecap.self, from: Data(json.utf8))
        XCTAssertNil(recap.jobs)
        let lenient = try TodoHubClient.makeDecoder().decode(WeeklyRecap.self, from: Data(#"{"week":"2026-11-02"}"#.utf8))
        XCTAssertTrue(lenient.sections.isEmpty)
        XCTAssertEqual(lenient.totals, WeeklyTotals(commits: 0, conversations: 0, runs: 0))
    }

    func testWeeklyRecapsSendsBeforeAndLimit() async throws {
        respond("[\(fixture)]")
        let recaps = try await client().weeklyRecaps(before: "2026-11-09", limit: 2)
        XCTAssertEqual(recaps.count, 1)
        XCTAssertEqual(lastRequest.httpMethod, "GET")
        let url = try XCTUnwrap(lastRequest.url)
        XCTAssertEqual(url.path, "/api/weekly")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, ["before": "2026-11-09", "limit": "2"])

        respond("[]")
        _ = try await client().weeklyRecaps()
        let defaults = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(lastRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(defaults, ["limit": "4"])
    }

    func testRewriteWeeklyPostsToPath() async throws {
        respond("{\"ok\":true}")
        try await client().rewriteWeekly(projectId: "p", week: "2026-11-02")
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        XCTAssertEqual(lastRequest.url?.path, "/api/projects/p/weekly/2026-11-02/rewrite")
    }

    func testLabels() throws {
        let recap = try TodoHubClient.makeDecoder().decode(WeeklyRecap.self, from: Data(fixture.utf8))
        XCTAssertEqual(recap.label, "Week of Mon 2 Nov")
        XCTAssertEqual(recap.windowLabel, "Mon 2 Nov 08:00 → Mon 9 Nov 08:00")
        let odd = try TodoHubClient.makeDecoder().decode(WeeklyRecap.self, from: Data(#"{"week":"junk"}"#.utf8))
        XCTAssertEqual(odd.label, "Week of junk")
    }
}
