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
    private var mappingTruncated = false
    private var mappingFails = false
    /// The diff on screen renames the file.
    private var renamed = false
    /// While set, `send` waits for the second press to arrive.
    private var holdSend = false
    private var heldSend: CheckedContinuation<Void, Never>?
    /// While set, the uncommitted diff waits for `release()`.
    private var holdUncommitted = false
    private var held: CheckedContinuation<Void, Never>?

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
            if mappingFails { return SSHExecResult(exitCode: 65, stdout: "", stderr: "gone") }
            let patch = mappingTruncated ? "" : mapping
            return json(["from": "rev1", "to": revision, "scope": "since", "patch": patch, "truncated": mappingTruncated])
        }
        if command.contains(" diff ") {
            let scope = command.contains("--scope branch") ? "branch" : "uncommitted"
            if scope == "uncommitted", holdUncommitted {
                await withCheckedContinuation { held = $0 }
            }
            let patch = renamed
                ? "diff --git a/f.txt b/g.txt\nsimilarity index 90%\nrename from f.txt\nrename to g.txt\n--- a/f.txt\n+++ b/g.txt\n@@ -1,2 +1,3 @@\n a\n+inserted\n b\n"
                : "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,3 @@\n a\n+inserted\n b\n"
            return json(["from": "head1", "to": revision, "scope": scope, "patch": patch, "truncated": false])
        }
        if command.contains(" keep ") { return json(["kept": revision]) }
        if command.contains(" send ") {
            if holdSend { await withCheckedContinuation { heldSend = $0 } }
            return SSHExecResult(exitCode: sendExit, stdout: "{}", stderr: "")
        }
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

    func testAnOlderLoadFinishingLastIsDropped() async throws {
        let (session, _) = makeSession()
        holdUncommitted = true
        let first = Task { await session.load(config: config) }
        while held == nil { await Task.yield() }
        session.scope = .branch
        await session.load(config: config)
        XCTAssertEqual(session.result?.scope, "branch")
        held?.resume()
        await first.value
        XCTAssertEqual(session.result?.scope, "branch")
        XCTAssertFalse(session.isLoading)
    }

    func testACutOffMappingLeavesCommentsPastTheCutUnplaced() async {
        let (session, store) = makeSession()
        mappingTruncated = true
        let old = ReviewComment(path: "f.txt", startLine: 2, endLine: nil, revision: "rev1", quote: ["b"], body: "x")
        store.update(session.key) { $0.comments.append(old) }
        await session.load(config: config)
        XCTAssertNil(session.anchors[old.id])
        XCTAssertEqual(session.otherComments(file: session.diff.files[0]).map(\.id), [old.id])
    }

    func testASecondSendWhileTheFirstRunsDoesNothing() async {
        let (session, store) = makeSession()
        await session.load(config: config)
        session.addComment(path: "f.txt", side: .new, lines: 2...2, quote: ["inserted"], body: "x")
        holdSend = true
        let first = Task { await session.send(config: config) }
        while heldSend == nil { await Task.yield() }
        await session.send(config: config)
        heldSend?.resume()
        await first.value
        XCTAssertEqual(commands.filter { $0.contains(" send ") }.count, 1)
        XCTAssertEqual(store.record(session.key).batches.count, 1)
    }

    func testACommentAddedDuringALoadKeepsItsPlace() async {
        let (session, _) = makeSession()
        await session.load(config: config)
        holdUncommitted = true
        let reload = Task { await session.load(config: config) }
        while held == nil { await Task.yield() }
        session.addComment(path: "f.txt", side: .new, lines: 2...2, quote: ["inserted"], body: "x")
        held?.resume()
        await reload.value
        let id = session.drafts[0].id
        XCTAssertEqual(session.anchors[id], .moved(path: "f.txt", startLine: 2, endLine: nil))
        XCTAssertFalse(session.message().contains("changed since"))
    }

    func testAStaleCommentOnARenamedFileStillShows() async {
        let (session, store) = makeSession()
        renamed = true
        let old = ReviewComment(path: "f.txt", startLine: 1, endLine: nil, revision: "rev1", quote: ["a"], body: "x")
        store.update(session.key) { $0.comments.append(old) }
        mappingFails = true
        await session.load(config: config)
        XCTAssertEqual(session.diff.files.map(\.path), ["g.txt"])
        XCTAssertEqual(session.otherComments(file: session.diff.files[0]).map(\.id), [old.id])
        XCTAssertTrue(session.commentsOutsideDiff().isEmpty)
        // Its comparison failed: the message says so instead of claiming the lines changed.
        XCTAssertEqual(session.unchecked(), [old.id])
        XCTAssertTrue(session.message().contains("not checked against the current code"), session.message())
    }

    func testAnUnreadableStoreFileIsKeptAside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("review-comments.json")
        try Data("{not json".utf8).write(to: url)
        let store = ReviewStore(fileURL: url)
        store.update("k") { $0.comments.append(ReviewComment(path: "a", startLine: 1, endLine: nil, revision: "r", quote: [], body: "b")) }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.count, 2, "\(names)")
        let aside = try XCTUnwrap(names.first { $0.contains("unreadable") })
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(aside), encoding: .utf8), "{not json")
    }

    func testSinceWithoutABatchFallsBackToUncommitted() async {
        let (session, _) = makeSession()
        session.scope = .since
        await session.load(config: config)
        XCTAssertEqual(session.scope, .uncommitted)
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
