import AISessionCore
import Foundation
import XCTest
@testable import AI_Session_Remote

/// The review window's logic against a scripted `ai-todo-review`.
@MainActor
final class ReviewSessionTests: XCTestCase {
    private let config = HostConnectionConfig(host: "mac", port: 22, username: "me", privateKeyPEM: Data())
    private var commands: [String] = []
    private var sendExit: Int32 = 0
    private var revision = "rev2"

    private let mapping = """
    diff --git a/f.txt b/f.txt
    --- a/f.txt
    +++ b/f.txt
    @@ -1,0 +2 @@
    +inserted

    """

    private func exec(_ config: HostConnectionConfig, _ command: String) async throws -> SSHExecResult {
        commands.append(command)
        func json(_ value: Any) -> SSHExecResult {
            let data = try! JSONSerialization.data(withJSONObject: value)
            return SSHExecResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
        }
        if command.contains(" status ") {
            return json(["root": "/w", "branch": "feat", "head": "head1", "revision": revision, "clean": false])
        }
        if command.contains(" diff "), command.contains("--unified 0") {
            return json(["from": "rev1", "to": revision, "scope": "since", "patch": mapping, "truncated": false])
        }
        if command.contains(" diff ") {
            let patch = "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,3 @@\n a\n+inserted\n b\n"
            return json(["from": "head1", "to": revision, "scope": "uncommitted", "patch": patch, "truncated": false])
        }
        if command.contains(" keep ") { return json(["kept": revision]) }
        if command.contains(" send ") { return SSHExecResult(exitCode: sendExit, stdout: "{}", stderr: "") }
        return SSHExecResult(exitCode: 1, stdout: "", stderr: "unexpected")
    }

    private func makeSession(status: ConversationStatus = .idle) -> (ReviewSession, ReviewStore) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = ReviewStore(fileURL: url)
        var conversation = DemoFixtures.conversations[0]
        conversation.status = status
        conversation.statusRevision = 4
        let session = ReviewSession(conversation: conversation, store: store, exec: { [unowned self] in
            try await self.exec($0, $1)
        })
        return (session, store)
    }

    func testCommentsOnAnOlderRevisionMoveWithTheirLines() async {
        let (session, store) = makeSession()
        let old = ReviewComment(path: "f.txt", startLine: 2, endLine: nil, revision: "rev1", quote: ["b"], body: "rename b")
        store.update(session.key) { $0.comments.append(old) }

        await session.load(config: config)

        XCTAssertNil(session.failure)
        XCTAssertEqual(session.diff.files.map(\.path), ["f.txt"])
        // A line was inserted after line 1, so line 2 of rev1 is line 3 now.
        XCTAssertEqual(session.anchors[old.id], .moved(path: "f.txt", startLine: 3, endLine: nil))
        XCTAssertEqual(session.comments(atPath: "f.txt", side: .new, endLine: 3).map(\.id), [old.id])
        XCTAssertTrue(commands.contains { $0.contains("--from 'rev1' --to 'rev2' --unified 0") })
    }

    func testSendTypesOneMessageAndMarksTheDraftsSent() async {
        let (session, store) = makeSession()
        await session.load(config: config)
        session.addComment(path: "f.txt", side: .new, lines: 2...2, quote: ["inserted"], body: "Why this line?")
        XCTAssertEqual(session.drafts.count, 1)

        await session.send(config: config)

        XCTAssertNil(session.failure)
        let send = try! XCTUnwrap(commands.last { $0.contains(" send ") })
        let start = try! XCTUnwrap(send.range(of: "printf '%s' '"))
        let encoded = send[start.upperBound...].prefix { $0 != "'" }
        let message = String(decoding: Data(base64Encoded: String(encoded))!, as: UTF8.self)
        XCTAssertTrue(message.contains("1. f.txt:2\n> inserted\nWhy this line?"), message)
        XCTAssertTrue(commands.contains { $0.contains(" keep ") && $0.contains("'rev2'") })
        let record = store.record(session.key)
        XCTAssertEqual(record.comments.map(\.state), [.sent])
        XCTAssertEqual(record.batches.first?.revision, "rev2")
        XCTAssertEqual(record.batches.first?.statusRevision, 4)
        XCTAssertTrue(session.drafts.isEmpty)
    }

    func testAFailedSendKeepsTheDrafts() async {
        let (session, store) = makeSession()
        await session.load(config: config)
        session.addComment(path: "f.txt", side: .new, lines: 1...2, quote: ["a", "inserted"], body: "x")
        sendExit = TmuxCommandBuilder.reviewNoSessionExitCode

        await session.send(config: config)

        XCTAssertNotNil(session.failure)
        XCTAssertEqual(store.record(session.key).comments.map(\.state), [.draft])
        XCTAssertTrue(store.record(session.key).batches.isEmpty)
    }

    func testWaitingConversationCantBeSentTo() async {
        let (session, _) = makeSession(status: .waiting)
        await session.load(config: config)
        session.addComment(path: "f.txt", side: .new, lines: 1...1, quote: ["a"], body: "x")
        XCTAssertNotNil(session.sendBlocker)
        await session.send(config: config)
        XCTAssertFalse(commands.contains { $0.contains(" send ") })
    }

    func testAgentAnsweredAfterTheNextIdleTurn() async {
        let (session, _) = makeSession()
        await session.load(config: config)
        session.addComment(path: "f.txt", side: .new, lines: 1...1, quote: ["a"], body: "x")
        await session.send(config: config)
        XCTAssertFalse(session.agentAnswered)

        var later = session.conversation
        later.statusRevision = 6
        later.status = .idle
        session.refresh(later)
        XCTAssertTrue(session.agentAnswered)
    }
}
