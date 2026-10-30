import AppKit
import AISessionCore
import XCTest
@testable import AI_Session_Remote

@MainActor
final class ReviewAcknowledgementTests: XCTestCase {
    private func conversation(status: ConversationStatus = .idle, revision: Int = 4) -> Conversation {
        var value = Conversation(id: "c", todoId: "t",
                                 computer: Computer(id: "m", name: "Mac", hostname: "mac", username: "me"),
                                 cwd: "~", tool: "claude", tmuxName: "test", sessionId: "s", status: status)
        value.statusRevision = revision
        return value
    }

    private func store() -> TodoHubStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewHub.self]
        let client = TodoHubClient(baseURL: URL(string: "http://hub.invalid")!, token: "test",
                                   session: URLSession(configuration: config))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return TodoHubStore(cache: TodoHubCache(fileURL: path), makeClient: { client })
    }

    private func respond(_ conversation: Conversation, code: Int = 200) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        ReviewHub.respond(code: code, body: try encoder.encode(conversation))
    }

    func testFailedAcknowledgementCanBeRetriedSuccessfully() async throws {
        let store = store()
        let original = conversation()
        var reviewed = original
        reviewed.reviewed = true
        try respond(reviewed, code: 503)
        let failed = await store.review(original)
        XCTAssertFalse(failed, "a failed post must not consume the view's review-on-open acknowledgement")
        try respond(reviewed)
        let retried = await store.review(original)
        XCTAssertTrue(retried)
    }

    func testNewerReviewedResultDoesNotAcknowledgeTheOlderResult() async throws {
        var newer = conversation(revision: 5)
        newer.reviewed = true
        try respond(newer)
        let acknowledged = await store().review(conversation(revision: 4))
        XCTAssertFalse(acknowledged)
    }

    func testBusyConversationDoesNotConsumeAcknowledgement() async {
        let acknowledged = await store().review(conversation(status: .busy))
        XCTAssertFalse(acknowledged)
    }
}

private final class ReviewHub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = (code: 200, body: Data())

    static func respond(code: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        response = (code, body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let response = Self.response
        Self.lock.unlock()
        let isReview = request.url!.path.hasSuffix("/review")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: isReview ? response.code : 200,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: isReview ? response.body : Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
