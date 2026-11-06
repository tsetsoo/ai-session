#if os(macOS)
import AISessionCore
import Foundation
import Observation

/// One review window's state: the worktree's status and diff on the conversation's computer,
/// where each comment sits in that diff, and sending drafts to the conversation.
@Observable
@MainActor
final class ReviewSession {
    /// Failures worded for the window: no SSH words, no raw remote output.
    struct Failure: LocalizedError, Equatable {
        let errorDescription: String?
    }

    private(set) var conversation: Conversation
    let store: ReviewStore
    var scope: ReviewScope = .uncommitted
    private(set) var status: ReviewStatus?
    private(set) var result: ReviewDiffResult?
    private(set) var diff = UnifiedDiff(files: [])
    /// Where each comment is in `result.to` (new side). Missing: not worked out (yet).
    private(set) var anchors: [UUID: ReviewAnchor] = [:]
    private(set) var isLoading = false
    private(set) var isSending = false
    var failure: Failure?
    /// Shown once after a send.
    var notice: String?

    @ObservationIgnored private let exec: (HostConnectionConfig, String) async throws -> SSHExecResult

    init(conversation: Conversation, store: ReviewStore = .shared,
         exec: @escaping (HostConnectionConfig, String) async throws -> SSHExecResult = { try await NIOSSHClient().exec($0, command: $1) }) {
        self.conversation = conversation
        self.store = store
        self.exec = exec
    }

    var key: String { conversation.listKey }
    var record: ReviewRecord { store.record(key) }
    var drafts: [ReviewComment] { record.drafts }

    /// The hub's newer copy of the same conversation (status changes).
    func refresh(_ conversation: Conversation) {
        if conversation.listKey == key, conversation != self.conversation { self.conversation = conversation }
    }

    /// The agent has finished a turn since the last batch went out.
    var agentAnswered: Bool {
        guard let batch = record.lastBatch, let sentAt = batch.statusRevision else { return false }
        return conversation.status == .idle && conversation.statusRevision > sentAt
    }

    /// Why Send is off, or nil.
    var sendBlocker: String? {
        if drafts.isEmpty { return "Write a comment first." }
        if conversation.tmuxName.isEmpty { return "This conversation has no terminal session." }
        if conversation.status == .waiting { return "The agent is waiting on a question. Answer it first." }
        if conversation.status == .closed { return "The conversation is closed. Open it first." }
        return nil
    }

    // MARK: Loading

    func load(config: HostConnectionConfig) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let status: ReviewStatus = try await run(TmuxCommandBuilder.reviewStatus(cwd: conversation.cwd), config: config)
            self.status = status
            var from: String?
            if scope == .since {
                guard let batch = record.lastBatch else {
                    scope = .uncommitted
                    return await load(config: config)
                }
                from = batch.revision
            }
            let result: ReviewDiffResult = try await run(
                TmuxCommandBuilder.reviewDiff(cwd: conversation.cwd, scope: scope, from: from, to: status.revision),
                config: config
            )
            self.result = result
            diff = UnifiedDiff(parsing: result.patch)
            failure = nil
            await placeComments(at: result.to, config: config)
        } catch {
            failure = Failure(errorDescription: message(for: error))
        }
    }

    /// Works out where every kept comment is in `revision`, one `--unified 0` diff per older
    /// revision. A revision that is gone (an unsent snapshot after gc) leaves its comments unplaced.
    private func placeComments(at revision: String, config: HostConnectionConfig) async {
        var placed: [UUID: ReviewAnchor] = [:]
        let live = record.comments.filter { $0.state != .dismissed && $0.side == .new }
        for (commentRevision, comments) in Dictionary(grouping: live, by: \.revision) {
            if commentRevision == revision {
                for comment in comments {
                    placed[comment.id] = .moved(path: comment.path, startLine: comment.startLine, endLine: comment.endLine)
                }
                continue
            }
            guard let between: ReviewDiffResult = try? await run(
                TmuxCommandBuilder.reviewDiff(cwd: conversation.cwd, scope: .since, from: commentRevision, to: revision, unified: 0),
                config: config
            ) else { continue }
            let mapping = UnifiedDiff(parsing: between.patch)
            for comment in comments { placed[comment.id] = ReviewAnchor.resolve(comment, through: mapping) }
        }
        anchors = placed
    }

    // MARK: Comments

    /// Adds a draft on lines of the diff on screen.
    func addComment(path: String, side: DiffSide, lines: ClosedRange<Int>?, quote: [String], body: String) {
        guard let result else { return }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let comment = ReviewComment(
            path: path, side: side, startLine: lines?.lowerBound,
            endLine: lines.map { $0.upperBound == $0.lowerBound ? nil : $0.upperBound } ?? nil,
            revision: side == .new ? result.to : result.from, quote: quote, body: text
        )
        store.update(key) { $0.comments.append(comment) }
        if side == .new {
            anchors[comment.id] = .moved(path: path, startLine: comment.startLine, endLine: comment.endLine)
        }
    }

    func editComment(_ id: UUID, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.update(key) { record in
            if let index = record.comments.firstIndex(where: { $0.id == id && $0.state == .draft }) {
                record.comments[index].body = text
            }
        }
    }

    func deleteComment(_ id: UUID) {
        store.update(key) { $0.comments.removeAll { $0.id == id && $0.state == .draft } }
        anchors[id] = nil
    }

    /// Hides a sent comment from the diff; it stays in the batch's history.
    func dismissComment(_ id: UUID) {
        store.update(key) { record in
            if let index = record.comments.firstIndex(where: { $0.id == id }) { record.comments[index].state = .dismissed }
        }
        anchors[id] = nil
    }

    /// Comments shown at a line of the diff on screen: new-side ones where they were placed,
    /// removed-line ones only on the diff they were written on.
    func comments(atPath path: String, side: DiffSide, endLine line: Int) -> [ReviewComment] {
        record.comments.filter { comment in
            guard comment.state != .dismissed else { return false }
            if comment.side == .old {
                return side == .old && comment.revision == result?.from && comment.path == path
                    && (comment.endLine ?? comment.startLine) == line
            }
            guard side == .new, case let .moved(movedPath, start, end)? = anchors[comment.id], let start else { return false }
            return movedPath == path && (end ?? start) == line
        }
    }

    /// Comments of a file that aren't on a line of the diff on screen: whole-file ones, ones on
    /// lines the diff doesn't show, and ones whose lines changed since.
    func otherComments(path: String, file: DiffFile) -> [ReviewComment] {
        let shownNew = Set(file.hunks.flatMap(\.lines).compactMap { $0.kind == .removed ? nil : $0.newLine })
        let shownOld = Set(file.hunks.flatMap(\.lines).compactMap { $0.kind == .removed ? $0.oldLine : nil })
        return record.comments.filter { comment in
            guard comment.state != .dismissed else { return false }
            if comment.side == .old {
                guard comment.path == path else { return false }
                return comment.revision != result?.from || !shownOld.contains(comment.endLine ?? comment.startLine ?? -1)
            }
            switch anchors[comment.id] {
            case let .moved(movedPath, start, end)?:
                guard movedPath == path else { return false }
                guard let start else { return true }
                return !shownNew.contains(end ?? start)
            case .stale?:
                return comment.path == path
            case nil:
                return comment.path == path
            }
        }
    }

    func isStale(_ comment: ReviewComment) -> Bool {
        if comment.side == .old { return comment.revision != result?.from }
        return anchors[comment.id] == .stale
    }

    /// Comments not tied to any file in this diff (their file has no changes in this scope).
    func commentsOutsideDiff() -> [ReviewComment] {
        let paths = Set(diff.files.map(\.path))
        return record.comments.filter { comment in
            guard comment.state != .dismissed else { return false }
            if case let .moved(path, _, _)? = anchors[comment.id] { return !paths.contains(path) }
            return !paths.contains(comment.path)
        }
    }

    func commentCount(path: String) -> Int {
        record.comments.filter { comment in
            guard comment.state != .dismissed else { return false }
            if case let .moved(movedPath, _, _)? = anchors[comment.id] { return movedPath == path }
            return comment.path == path
        }.count
    }

    // MARK: Sending

    /// The drafts as they will go out: moved to where their lines are now.
    func outgoing() -> [ReviewComment] {
        drafts.map { comment in
            guard comment.side == .new, case let .moved(path, start, end)? = anchors[comment.id] else { return comment }
            var moved = comment
            moved.path = path
            moved.startLine = start
            moved.endLine = end
            if let revision = result?.to { moved.revision = revision }
            return moved
        }
    }

    func message() -> String {
        ReviewMessage.render(outgoing(), branch: status?.branch, revision: result?.to ?? status?.revision ?? "",
                             includesUncommitted: status.map { !$0.clean } ?? false)
    }

    /// Keeps the revision on the computer, types the message into the conversation, and marks
    /// the drafts sent. Nothing is marked when the message didn't go.
    func send(config: HostConnectionConfig) async {
        guard sendBlocker == nil, let revision = result?.to else { return }
        isSending = true
        defer { isSending = false }
        let outgoing = outgoing()
        let text = message()
        do {
            let _: [String: String] = try await run(TmuxCommandBuilder.reviewKeep(cwd: conversation.cwd, revision: revision), config: config)
            let sent = try await exec(config, TmuxCommandBuilder.reviewSend(tmuxName: conversation.tmuxName, message: text))
            switch sent.exitCode {
            case TmuxCommandBuilder.reviewNoSessionExitCode:
                throw Failure(errorDescription: "The conversation isn't running on \(conversation.computer.name). Open it, then send again.")
            case TmuxCommandBuilder.reviewNotReadyExitCode:
                throw Failure(errorDescription: "The conversation can't take a message yet. Try again once it has started.")
            default:
                try RemoteConversations.check(sent, computerName: conversation.computer.name)
            }
        } catch {
            failure = Failure(errorDescription: message(for: error))
            return
        }
        let batch = ReviewBatch(commentIDs: outgoing.map(\.id), revision: revision, statusRevision: conversation.statusRevision)
        let byID = Dictionary(uniqueKeysWithValues: outgoing.map { ($0.id, $0) })
        store.update(key) { record in
            for index in record.comments.indices {
                guard var sent = byID[record.comments[index].id] else { continue }
                sent.state = .sent
                sent.sentAt = batch.sentAt
                sent.batchID = batch.id
                record.comments[index] = sent
            }
            record.batches.append(batch)
        }
        notice = outgoing.count == 1 ? "Sent 1 comment to the agent." : "Sent \(outgoing.count) comments to the agent."
    }

    // MARK: Remote

    private func run<T: Decodable>(_ command: String, config: HostConnectionConfig) async throws -> T {
        let output = try await exec(config, command)
        if output.exitCode == TmuxCommandBuilder.reviewNoRepositoryExitCode {
            throw Failure(errorDescription: "\(conversation.cwd) on \(conversation.computer.name) isn't a git repository.")
        }
        try RemoteConversations.check(output, computerName: conversation.computer.name)
        do {
            return try JSONDecoder().decode(T.self, from: Data(output.stdout.utf8))
        } catch {
            throw Failure(errorDescription: "Couldn't read the changes from \(conversation.computer.name).")
        }
    }

    private func message(for error: Error) -> String {
        if let failure = error as? Failure { return failure.errorDescription ?? "Something went wrong." }
        return ConversationRowActions.message(for: error, computer: conversation.computer)
    }
}
#endif
