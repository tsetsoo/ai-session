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
    /// `log --before`'s answer; nil = no commit that old.
    private var startCommit: String? = "start1"
    /// The conversation's folder answers exit 69 (gone, or not in git).
    private var folderGone = false
    /// `status --ref` answers exit 65 (the branch is gone too).
    private var branchGone = false
    /// `status`'s worktree_base.
    private var worktreeBase: String?
    /// The diff on screen renames the file.
    private var renamed = false
    /// While set, `send` waits for the second press to arrive.
    private var holdSend = false
    private var heldSend: CheckedContinuation<Void, Never>?
    /// While set, the uncommitted diff waits for `release()`.
    private var holdUncommitted = false
    private var held: CheckedContinuation<Void, Never>?
    /// `result` answers running this many times before it is done.
    private var runningPolls = 0
    private var resultPolls = 0
    private var reviewerMissing = false
    /// The run finished just before Cancel reached it.
    private var cancelFindsItDone = false
    /// The revision the fake reviewer read.
    private var reviewedRevision = "rev2"

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
        if command.contains(" log ") {
            let commits: [[String: Any]] = [
                ["sha": "head1", "subject": "latest", "date": "2026-11-06T19:00:00+02:00", "pushed": true],
                ["sha": "start1", "subject": "before the conversation", "date": "2026-11-01T09:00:00Z", "pushed": true],
            ]
            return json(["commits": commits, "before": startCommit as Any? ?? NSNull()])
        }
        if command.contains(" status ") {
            if command.contains("--ref") {
                if branchGone { return SSHExecResult(exitCode: 65, stdout: "", stderr: "no branch") }
                return json(["root": "/project", "branch": "ai/x-1", "head": "tip1", "revision": "tip1", "clean": true,
                             "ref": "ai/x-1"])
            }
            if folderGone { return SSHExecResult(exitCode: 69, stdout: "", stderr: "no folder") }
            return json(["root": "/w", "branch": "feat", "head": "head1", "revision": revision, "clean": false,
                         "worktree_base": worktreeBase as Any? ?? NSNull()])
        }
        if command.contains(" diff "), command.contains("--unified 0") {
            if mappingFails { return SSHExecResult(exitCode: 65, stdout: "", stderr: "gone") }
            let patch = mappingTruncated ? "" : mapping
            return json(["from": "rev1", "to": revision, "scope": "since", "patch": patch, "truncated": mappingTruncated])
        }
        if command.contains(" diff ") {
            let scope = command.contains("--scope branch") ? "branch" : command.contains("--scope since") ? "since" : "uncommitted"
            if scope == "uncommitted", holdUncommitted {
                await withCheckedContinuation { held = $0 }
            }
            let patch = renamed
                ? "diff --git a/f.txt b/g.txt\nsimilarity index 90%\nrename from f.txt\nrename to g.txt\n--- a/f.txt\n+++ b/g.txt\n@@ -1,2 +1,3 @@\n a\n+inserted\n b\n"
                : "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,3 @@\n a\n+inserted\n b\n"
            return json(["from": "head1", "to": revision, "scope": scope, "patch": patch, "truncated": false])
        }
        if command.contains(" keep ") { return json(["kept": revision]) }
        if command.contains(" run ") {
            if reviewerMissing { return SSHExecResult(exitCode: 90, stdout: "", stderr: "codex not found") }
            return json(["id": "x", "state": "running"])
        }
        if command.contains(" result ") || (command.contains(" cancel ") && cancelFindsItDone) {
            resultPolls += 1
            if resultPolls <= runningPolls { return json(["id": "x", "state": "running"]) }
            let finding: (String, Int, String) -> [String: Any] = { title, line, fingerprint in
                ["path": "f.txt", "side": "new", "line_start": line, "line_end": line, "severity": title == "Low one" ? "low" : "high", "category": "correctness",
                 "title": title, "body": "fix", "quote": ["x"], "fingerprint": fingerprint]
            }
            let output: [String: Any] = ["tool": "claude", "model": "m", "from": "head1", "to": reviewedRevision, "summary": "ok",
                                         "usage": NSNull(), "findings": [finding("Inserted is wrong", 2, "fp-a"), finding("Low one", 1, "fp-b")]]
            return json(["id": "x", "state": "done", "error": NSNull(), "result": output])
        }
        if command.contains(" cancel ") { return json(["id": "x", "state": "cancelled"]) }
        if command.contains(" send ") {
            if holdSend { await withCheckedContinuation { heldSend = $0 } }
            return SSHExecResult(exitCode: sendExit, stdout: "{}", stderr: "")
        }
        return SSHExecResult(exitCode: 1, stdout: "", stderr: "unexpected")
    }

    private func makeSession(status: ConversationStatus = .idle, worktree: Bool = false) -> (ReviewSession, ReviewStore) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = ReviewStore(fileURL: url, makeClient: { nil })
        var conversation = DemoFixtures.conversations[0]
        conversation.status = status
        conversation.statusRevision = 4
        if worktree {
            conversation.worktreeSource = "/project"
            conversation.branch = "ai/x-1"
        }
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
        let store = ReviewStore(fileURL: url, makeClient: { nil })
        store.update("k") { $0.comments.append(ReviewComment(path: "a", startLine: 1, endLine: nil, revision: "r", quote: [], body: "b")) }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.count, 2, "\(names)")
        let aside = try XCTUnwrap(names.first { $0.contains("unreadable") })
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(aside), encoding: .utf8), "{not json")
    }

    func testConversationScopeStartsAtTheLastCommitBeforeItBegan() async throws {
        let (session, _) = makeSession()
        session.scope = .conversation
        await session.load(config: config)
        XCTAssertNil(session.failure)
        let log = try XCTUnwrap(commands.first { $0.contains(" log ") })
        // The hub's UTC time, as ISO for git.
        XCTAssertTrue(log.contains("--before '\(ReviewSession.gitTime(session.conversation.createdAt) ?? "?")'"), log)
        XCTAssertTrue(commands.contains { $0.contains(" diff ") && $0.contains("--scope since --from 'start1'") })
        XCTAssertEqual(session.conversationStart, "start1")
        XCTAssertEqual(session.commits.map(\.sha), ["head1", "start1"])
    }

    func testConversationScopeWithoutAnOlderCommitSaysSo() async {
        let (session, _) = makeSession()
        startCommit = nil
        session.scope = .conversation
        await session.load(config: config)
        XCTAssertNotNil(session.failure)
        XCTAssertFalse(commands.contains { $0.contains(" diff ") && !$0.contains("--unified 0") })
    }

    func testCompareWithACommit() async throws {
        let (session, _) = makeSession()
        await session.load(config: config)
        session.compare(from: try XCTUnwrap(session.commits.last))
        XCTAssertEqual(session.scope, .commit)
        await session.load(config: config)
        XCTAssertTrue(commands.contains { $0.contains("--scope since --from 'start1'") })
    }

    func testAWorktreeConversationStartsAtItsBase() async {
        let (session, _) = makeSession()
        worktreeBase = "wtbase1"
        session.scope = .conversation
        await session.load(config: config)
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.conversationStart, "wtbase1")
        XCTAssertTrue(commands.contains { $0.contains(" diff ") && $0.contains("--from 'wtbase1'") })
    }

    func testAGoneWorktreeReviewsItsKeptBranch() async {
        let (session, _) = makeSession(worktree: true)
        folderGone = true
        await session.load(config: config)
        // Nothing is uncommitted on a kept branch: the window moves to Branch, which loads it.
        XCTAssertEqual(session.scope, .branch)
        await session.load(config: config)
        XCTAssertNil(session.failure)
        XCTAssertNotNil(session.keptBranch)
        XCTAssertEqual(session.status?.ref, "ai/x-1")
        XCTAssertTrue(commands.contains { $0.contains(" diff '/project' --scope branch") && $0.contains("--ref 'ai/x-1'") })
        XCTAssertTrue(commands.contains { $0.contains(" log '/project'") && $0.contains("--ref 'ai/x-1'") })
    }

    func testAGoneWorktreeWithAGoneBranchSaysSo() async {
        let (session, _) = makeSession(worktree: true)
        folderGone = true
        branchGone = true
        await session.load(config: config)
        XCTAssertTrue(session.failure?.errorDescription?.contains("so is its branch ai/x-1") == true, "\(String(describing: session.failure))")
    }

    func testAFolderOutsideGitExplainsWhy() async {
        let (session, _) = makeSession()
        folderGone = true
        await session.load(config: config)
        XCTAssertTrue(session.failure?.errorDescription?.contains("isn't in a git repository") == true, "\(String(describing: session.failure))")
        XCTAssertTrue(session.failure?.errorDescription?.contains("get their own worktree") == true)
    }

    func testGitTimeReadsTheHubsUTC() {
        XCTAssertEqual(ReviewSession.gitTime("2026-10-15 20:17:27"), "2026-10-15T20:17:27Z")
        XCTAssertNil(ReviewSession.gitTime(""))
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

    func testABusyAgentCantBeSentToAndSaysWhy() async {
        let (session, _) = makeSession(status: .busy)
        await session.load(config: config)
        session.addComment(path: "f.txt", side: .new, lines: 1...1, quote: ["a"], body: "x")
        let sent = await session.send(config: config)
        XCTAssertFalse(sent)
        XCTAssertNotNil(session.failure, "a blocked send must say why, or the sheet closes as if it went")
        XCTAssertFalse(commands.contains { $0.contains(" send ") })
    }

    func testAMappingIsFetchedOncePerPairOfRevisions() async {
        let (session, store) = makeSession()
        let old = ReviewComment(path: "f.txt", startLine: 2, endLine: nil, revision: "rev1", quote: ["b"], body: "x")
        store.update(session.key) { $0.comments.append(old) }
        await session.load(config: config)
        await session.load(config: config)
        XCTAssertEqual(commands.filter { $0.contains("--unified 0") }.count, 1)
        XCTAssertEqual(session.anchors[old.id], .moved(path: "f.txt", startLine: 3, endLine: nil))
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

    // MARK: Reviewer

    func testAReviewRunsFollowsAndAddsItsFindingsOnce() async throws {
        let (session, store) = makeSession()
        session.pollInterval = .milliseconds(1)
        await session.load(config: config)
        runningPolls = 2
        await session.startReview(tool: "claude", brief: "Fix it", config: config)
        let run = try XCTUnwrap(session.activeRun)
        XCTAssertEqual(session.reviewBlocker, "A review is running.")
        let start = try XCTUnwrap(commands.first { $0.contains(" run ") })
        XCTAssertTrue(start.contains("--from 'head1' --to 'rev2' --tool 'claude' --id '\(run.hostID)'"), start)
        XCTAssertTrue(start.contains("--brief-base64"), start)
        await session.followReview(config: config)
        XCTAssertNil(session.activeRun)
        XCTAssertEqual(resultPolls, 3)
        let finished = try XCTUnwrap(store.record(session.key).lastRun)
        XCTAssertEqual(finished.state, .done)
        XCTAssertEqual(finished.findingCount, 2)
        XCTAssertEqual(finished.addedCount, 2)
        // Highest severity first; placed where they are, so the diff shows them on their lines.
        let found = session.findings(.new)
        XCTAssertEqual(found.map(\.title), ["Inserted is wrong", "Low one"])
        XCTAssertEqual(session.comments(atPath: "f.txt", side: .new, endLine: 2).map(\.id), [found[0].id])
        XCTAssertEqual(session.findingMarks(file: session.diff.files[0]), [1: "low", 2: "high"])
        // Findings aren't drafts until picked: nothing to send yet.
        XCTAssertEqual(session.sendBlocker, "Write a comment first.")

        // The same findings again: nothing new.
        resultPolls = 0
        runningPolls = 0
        await session.startReview(tool: "claude", brief: nil, config: config)
        await session.followReview(config: config)
        XCTAssertEqual(store.record(session.key).lastRun?.addedCount, 0)
        XCTAssertEqual(store.record(session.key).comments.count, 2)
        XCTAssertTrue(commands.last { $0.contains(" run ") }?.contains("</dev/null") == true)
    }

    func testPickedFindingsGoOutWithTheUsersComments() async throws {
        let (session, store) = makeSession()
        session.pollInterval = .milliseconds(1)
        await session.load(config: config)
        await session.startReview(tool: "claude", brief: nil, config: config)
        await session.followReview(config: config)
        let found = session.findings(.new)
        session.queueFinding(found[0].id)
        session.dismissComment(found[1].id)
        XCTAssertEqual(session.findings(.dismissed).map(\.id), [found[1].id])
        XCTAssertTrue(session.findingMarks(file: session.diff.files[0]).isEmpty == false)
        session.addComment(path: "f.txt", side: .new, lines: 1...1, quote: ["a"], body: "mine")
        XCTAssertNil(session.sendBlocker)
        XCTAssertTrue(session.message().contains("[high] Inserted is wrong\nfix"), session.message())
        let sent = await session.send(config: config)
        XCTAssertTrue(sent)
        XCTAssertEqual(session.findings(.sent).map(\.id), [found[0].id])
        XCTAssertEqual(store.record(session.key).batches.last?.commentIDs.count, 2)
        // Restored, it is new again; unpicking moves a picked one back.
        session.restoreFinding(found[1].id)
        XCTAssertEqual(session.findings(.new).map(\.id), [found[1].id])
        session.queueFinding(found[1].id)
        XCTAssertEqual(session.drafts.map(\.id), [found[1].id])
        session.queueFinding(found[1].id, false)
        XCTAssertTrue(session.drafts.isEmpty)
    }

    func testFindingsOnAnOlderRevisionMoveWithTheirLines() async throws {
        let (session, _) = makeSession()
        session.pollInterval = .milliseconds(1)
        reviewedRevision = "rev1"
        await session.load(config: config)
        await session.startReview(tool: "claude", brief: nil, config: config)
        await session.followReview(config: config)
        // finishRun reloads to place them. rev1 → rev2 inserted a line after line 1: rev1's
        // line 2 is line 3 now.
        func inserted() -> ReviewComment? { session.findings(.new).first { $0.title == "Inserted is wrong" } }
        for _ in 0..<400 where inserted().map({ session.place(of: $0).line }) != 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.findings(.new).map(\.title), ["Inserted is wrong", "Low one"])
        XCTAssertEqual(inserted().map { session.place(of: $0).line }, 3)
        XCTAssertTrue(session.findings(.stale).isEmpty)
    }

    func testAMissingReviewerAndCancel() async throws {
        let (session, store) = makeSession()
        await session.load(config: config)
        reviewerMissing = true
        await session.startReview(tool: "codex", brief: nil, config: config)
        XCTAssertEqual(session.failure?.errorDescription, "codex isn't installed on \(session.conversation.computer.name), so it can't review there.")
        XCTAssertNil(session.activeRun)
        reviewerMissing = false
        session.failure = nil
        await session.startReview(tool: "claude", brief: nil, config: config)
        XCTAssertNotNil(session.activeRun)
        await session.cancelReview(config: config)
        XCTAssertNil(session.activeRun)
        XCTAssertEqual(store.record(session.key).lastRun?.state, .cancelled)
        XCTAssertTrue(session.findings(.new).isEmpty)
    }

    func testCancellingARunThatJustFinishedKeepsItsFindings() async throws {
        let (session, store) = makeSession()
        await session.load(config: config)
        await session.startReview(tool: "claude", brief: nil, config: config)
        cancelFindsItDone = true
        await session.cancelReview(config: config)
        XCTAssertEqual(store.record(session.key).lastRun?.state, .done)
        XCTAssertEqual(session.findings(.new).count, 2)
    }
}
