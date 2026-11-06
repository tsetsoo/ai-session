@testable import AISessionCore
import XCTest

/// A computer's doctor report: decoding what `ai-todo-status doctor` prints, what needs
/// attention, and the hub request for the last report.
final class HealthModelsTests: XCTestCase {
    /// Trimmed from a real report (2026-11-06).
    static let doctorJSON = """
    {"doctor_version": 3, "protocol_version": 2, "checked_ns": 1793978677941657000, "hostname": "mac.local",
     "codex": "/Users/me/.codex/packages/app-server-daemon/current/bin/codex", "runtime_connected": true,
     "status_service": {"protocol_version": 2, "delivery": {"pending": 1}}, "service_running": true,
     "tools": {
       "cursor": {"installed": true, "path": "/Users/me/.local/bin/agent", "version": "2026.10.19-6bbf2c4",
                  "method": "native", "auth": {"logged_in": false}},
       "claude": {"installed": true, "path": "/Users/me/.local/bin/claude", "resolved": "/x/2.1.319", "version": "2.1.319",
                  "method": "native", "auth": {"logged_in": true, "method": "claude.ai", "expires_at": "2026-11-30T12:26:32.471Z"}},
       "codex": {"installed": true, "version": "0.167.0", "method": "managed", "auth": {"logged_in": true, "method": "ChatGPT"},
                 "daemon": {"status": "running", "version": "0.167.0"}}},
     "runtime_threads": 22, "runtime_count": 16,
     "hooks": [{"eventName": "preToolUse", "enabled": true, "trustStatus": "trusted"},
               {"eventName": "stop", "enabled": true, "trustStatus": "untrusted"}],
     "claude_service": {"checked_ns": 1, "runtime_connected": true, "threads": 53, "fresh": true},
     "claude": {"binary": "/Users/me/.local/bin/claude", "threads": 53, "connected": true},
     "deliveries": {"in_flight": 0, "unlinked": 67, "failing": 1, "oldest_failing_s": 33106, "errors": {"timeout": 1}},
     "pending": 68,
     "helpers": {"commit": null, "dirty": null, "installed_at": null, "digest": "bb454ff2678edbb5", "files": 18},
     "running": [
       {"tmux": "ai/claude/todo-0089ed91", "tool": "claude", "pid": 97754, "session_id": "26ee", "path": "/x/2.1.310",
        "version": "2.1.310", "outdated": true},
       {"tmux": "ai/claude/todo-0566fb0a", "tool": "claude", "pid": 46120, "session_id": "d41f", "version": "2.1.319", "outdated": false},
       {"tmux": "ai/codex/todo-03d1a969", "tool": "codex", "pid": 80487, "session_id": null, "backend_pid": 80498,
        "version": "0.167.0", "backend_version": "0.166.0", "outdated": true},
       {"tmux": "ai/claude/todo-596db4e9", "tool": "claude", "pid": 829, "session_id": null, "version": null, "outdated": null}],
     "future_field": {"anything": [1, 2]}}
    """

    private func decode(_ json: String) throws -> HostHealth {
        try HostHealth.decode(Data(json.utf8))
    }

    func testDecodesTheDoctorReport() throws {
        let health = try decode(Self.doctorJSON)
        XCTAssertFalse(health.isOldScript)
        XCTAssertEqual(health.checkedAt?.timeIntervalSince1970 ?? 0, 1_793_978_677.94, accuracy: 0.01)
        XCTAssertEqual(health.orderedTools.map(\.name), ["claude", "codex", "cursor"])
        let claude = try XCTUnwrap(health.tools?["claude"])
        XCTAssertEqual(claude.version, "2.1.319")
        XCTAssertEqual(claude.auth?.loggedIn, true)
        XCTAssertEqual(claude.auth?.expiresAt, "2026-11-30T12:26:32.471Z")
        XCTAssertEqual(health.tools?["codex"]?.daemon?.version, "0.167.0")
        XCTAssertEqual(health.deliveries?.failing, 1)
        XCTAssertEqual(health.deliveries?.unlinked, 67)
        XCTAssertEqual(health.helpers?.digest, "bb454ff2678edbb5")
        XCTAssertEqual(health.running?.count, 4)
        XCTAssertEqual(health.outdatedRunning.map(\.tmux), ["ai/claude/todo-0089ed91", "ai/codex/todo-03d1a969"])
        XCTAssertEqual(health.outdatedRunning.last?.backendVersion, "0.166.0")
    }

    func testProblemsNameWhatNeedsAttentionOnly() throws {
        let problems = try decode(Self.doctorJSON).problems
        XCTAssertEqual(problems.map(\.kind), [.loggedOut, .hooks, .deliveries, .outdated])
        XCTAssertEqual(problems[0].text, "Cursor isn't logged in.")
        XCTAssertEqual(problems[1].text, "1 Codex status hook isn't trusted or enabled.")
        XCTAssertEqual(problems[2].text, "1 status update hasn't reached the hub (oldest 9 h).")
        XCTAssertEqual(problems[3].text, "2 conversations run an older version than the one installed.")
    }

    func testAnOlderScriptIsSaidSoAndUnknownsAreNotProblems() throws {
        // The doctor before versions: no doctor_version, tools, deliveries or running.
        let old = try decode("""
        {"protocol_version": 2, "codex": "/x/codex", "runtime_connected": true, "service_running": false,
         "pending": 69, "claude_service": {"fresh": false}}
        """)
        XCTAssertTrue(old.isOldScript)
        XCTAssertEqual(old.problems.map(\.kind), [.oldScript, .monitor, .monitor])
        let empty = try decode("{\"doctor_version\": 3}")
        XCTAssertEqual(empty.problems, [], "nothing known is not a problem")
        XCTAssertEqual(empty.outdatedRunning, [])
    }

    func testDurations() {
        XCTAssertEqual(HostHealth.duration(45), "45 s")
        XCTAssertEqual(HostHealth.duration(600), "10 min")
        XCTAssertEqual(HostHealth.duration(33106), "9 h")
        XCTAssertEqual(HostHealth.duration(3 * 86400), "3 days")
    }

    func testDoctorCommandRunsTheInstalledScript() {
        XCTAssertTrue(TmuxCommandBuilder.doctor.hasSuffix("\"$HOME/.ai-remote/bin/ai-todo-status\" doctor"))
    }

    // MARK: Hub

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

    func testFetchesTheLastReport() async throws {
        let body = #"{"computer_id": "mac 1", "reported_at": "2026-11-06T16:30:00Z", "report": "# + Self.doctorJSON + "}"
        StubURLProtocol.handler = { _ in .init(status: 200, body: body) }
        let snapshot = try await client().computerHealth(id: "mac 1")
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://pi.tailnet:8080/api/computers/mac%201/health")
        XCTAssertEqual(snapshot.computerId, "mac 1")
        XCTAssertEqual(snapshot.reportedDate, ISO8601DateFormatter().date(from: "2026-11-06T16:30:00Z"))
        XCTAssertEqual(snapshot.report?.tools?["codex"]?.version, "0.167.0")
    }

    func testNoReportYetAndAnOlderHub() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, body: #"{"computer_id": "mac", "reported_at": null, "report": null}"#) }
        let none = try await client().computerHealth(id: "mac")
        XCTAssertNil(none.report)
        XCTAssertNil(none.reportedDate)
        StubURLProtocol.handler = { _ in .init(status: 404, body: "") }
        do {
            _ = try await client().computerHealth(id: "mac")
            XCTFail("expected an error")
        } catch let error as TodoHubError {
            guard case .notFound = error else { return XCTFail("\(error)") }
        }
    }
}
