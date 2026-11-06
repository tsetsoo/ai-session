import XCTest
@testable import AISessionCore

final class PullRequestLinkTests: XCTestCase {
    private func decode(_ json: String) throws -> Conversation {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Conversation.self, from: Data(json.utf8))
    }

    private let base = #""todo_id":"t","computer":{"id":"m","name":"Mac","hostname":"mac","port":22,"username":"me","created_at":"","updated_at":""},"cwd":"~/a","tmux_name":"n","session_id":"s","status":"idle""#

    func testDecodesThePullRequest() throws {
        let c = try decode("{\(base),\"pull_request\":{\"url\":\"https://github.com/o/r/pull/12\",\"state\":\"merged\"}}")
        XCTAssertEqual(c.pullRequest, PullRequestLink(url: "https://github.com/o/r/pull/12", state: "merged"))
        XCTAssertNil(try decode("{\(base)}").pullRequest, "older hubs send none")
        XCTAssertNil(try decode("{\(base),\"pull_request\":{\"url\":3}}").pullRequest, "an unreadable one is dropped, not the list")
    }

    func testTitles() {
        XCTAssertEqual(PullRequestLink(url: "https://github.com/o/r/pull/12", state: "open").title, "PR #12 · open")
        let mr = PullRequestLink(url: "https://gitlab.com/g/r/-/merge_requests/45#note", state: "merged")
        XCTAssertTrue(mr.isMergeRequest)
        XCTAssertEqual(mr.number, 45)
        XCTAssertEqual(mr.title, "MR !45 · merged")
        XCTAssertEqual(PullRequestLink(url: "https://example.com/x", state: "closed").title, "PR · closed")
    }
}
