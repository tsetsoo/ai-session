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
        /// Exit 65: a revision or branch the repository doesn't have.
        var isUnknownRevision = false
    }

    private(set) var conversation: Conversation
    let store: ReviewStore
    var scope: ReviewScope = .uncommitted
    /// The commit `ReviewScope.commit` compares from (Compare With).
    private(set) var baseCommit: ReviewLog.Commit?
    /// Recent commits for Compare With, from the last load.
    private(set) var commits: [ReviewLog.Commit] = []
    /// Where the conversation started, from the last load: its worktree's base, else the
    /// last commit before the hub created it.
    private(set) var conversationStart: String?
    /// The conversation's worktree is gone but its branch is kept in the project folder: the
    /// window reviews that branch (committed work only).
    private(set) var keptBranch: (folder: String, branch: String)?

    /// Where the reads run: the conversation's folder, or the project folder with `--ref`.
    private var source: (cwd: String, ref: String?) {
        keptBranch.map { ($0.folder, $0.branch) } ?? (conversation.cwd, nil)
    }

    /// The folder isn't in a git repository (exit 69), as opposed to any other failure.
    struct NotARepository: Error {}
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
        // Sent mid-turn, the turn's own end would read as the answer to the feedback.
        if conversation.status == .busy { return "The agent is working. Send once it has finished its turn." }
        if conversation.status == .closed { return "The conversation is closed. Open it first." }
        return nil
    }

    // MARK: Loading

    /// Loads the scope on screen. A newer load (another scope, Refresh) supersedes this one:
    /// whatever this one gets back after that is dropped, so the window never shows one
    /// scope's diff under another's name.
    func load(config: HostConnectionConfig) async {
        loadGeneration += 1
        let generation = loadGeneration
        let scope = scope
        var from: String?
        switch scope {
        case .since:
            guard let batch = record.lastBatch else {
                // The picker's change restarts the load.
                self.scope = .uncommitted
                return
            }
            from = batch.revision
        case .commit:
            guard let baseCommit else {
                self.scope = .uncommitted
                return
            }
            from = baseCommit.sha
        case .uncommitted where keptBranch != nil:
            // A kept branch has nothing uncommitted; what it has is on the branch.
            self.scope = .branch
            return
        case .uncommitted, .branch, .conversation:
            break
        }
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        let knownAtStart = Set(record.comments.map(\.id))
        do {
            let status = try await locate(config: config)
            guard generation == loadGeneration else { return }
            if keptBranch != nil, scope == .uncommitted {
                self.status = status
                self.scope = .branch
                return
            }
            let (cwd, ref) = source
            let started = Self.gitTime(conversation.createdAt)
            // The history for Compare With and the conversation's start come with every load.
            let log: ReviewLog? = try? await run(TmuxCommandBuilder.reviewLog(cwd: cwd, before: started, ref: ref), config: config)
            guard generation == loadGeneration else { return }
            if let log { commits = log.commits }
            // A worktree knows where it began; otherwise the last commit before the hub made it.
            conversationStart = status.worktreeBase ?? log?.before
            if scope == .conversation {
                guard let start = conversationStart else {
                    throw Failure(errorDescription: started == nil || log == nil
                        ? "Couldn't tell where this conversation started. Choose Branch or Compare With."
                        : "There's no commit from before this conversation started. Choose Branch or Compare With.")
                }
                from = start
            }
            let result: ReviewDiffResult = try await run(
                TmuxCommandBuilder.reviewDiff(cwd: cwd, scope: scope, from: from, to: status.revision, ref: ref),
                config: config
            )
            guard generation == loadGeneration else { return }
            let placed = await placeComments(at: result.to, config: config)
            guard generation == loadGeneration else { return }
            self.status = status
            self.result = result
            diff = UnifiedDiff(parsing: result.patch)
            // Comments written while this load ran aren't in `placed`. One on the revision now
            // on screen stays where it is; one on the old revision is placed by the next load.
            var merged = placed
            for comment in record.comments where !knownAtStart.contains(comment.id) && comment.side == .new
                && comment.revision == result.to {
                merged[comment.id] = .moved(path: comment.path, startLine: comment.startLine, endLine: comment.endLine)
            }
            anchors = merged
            failure = nil
        } catch {
            guard generation == loadGeneration else { return }
            failure = Failure(errorDescription: message(for: error))
        }
    }

    @ObservationIgnored private var loadGeneration = 0

    /// The conversation's folder when it is in git. When it isn't: the kept branch of its
    /// worktree in the project folder, or a failure that says why there's nothing to review.
    private func locate(config: HostConnectionConfig) async throws -> ReviewStatus {
        do {
            let status: ReviewStatus = try await run(TmuxCommandBuilder.reviewStatus(cwd: conversation.cwd), config: config)
            keptBranch = nil
            return status
        } catch is NotARepository {
            guard let worktree = conversation.worktree else {
                throw Failure(errorDescription: "This conversation's folder, \(conversation.cwd), isn't in a git repository on "
                    + "\(conversation.computer.name), so there are no changes to review. New conversations in a git project "
                    + "get their own worktree and can be reviewed.")
            }
            do {
                let status: ReviewStatus = try await run(
                    TmuxCommandBuilder.reviewStatus(cwd: worktree.folder, ref: worktree.branch), config: config
                )
                keptBranch = worktree
                return status
            } catch let failure as Failure where failure.isUnknownRevision {
                throw Failure(errorDescription: "This conversation's worktree is gone from \(conversation.computer.name), "
                    + "and so is its branch \(worktree.branch). There's nothing left to review.")
            } catch is NotARepository {
                throw Failure(errorDescription: "This conversation's worktree is gone from \(conversation.computer.name), "
                    + "and its project folder \(worktree.folder) isn't a git repository there any more.")
            }
        }
    }

    /// Compare With: everything since `commit`. The window's scope change starts the load.
    func compare(from commit: ReviewLog.Commit) {
        baseCommit = commit
        scope = .commit
    }

    /// The hub's `2026-10-15 20:17:27` (UTC) as the ISO time git's `--before` reads.
    static func gitTime(_ hubTime: String) -> String? {
        guard let date = HubDates.date(from: hubTime) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
    @ObservationIgnored private var mappingCache: [String: ReviewDiffResult] = [:]
    static let mappingConcurrency = 4

    /// Where every kept new-side comment is in `revision`: one `--unified 0` diff per older
    /// revision, fetched at the same time. A comment stays unplaced when its revision is gone
    /// or the diff failed, and when its file is past the end of a cut-off diff (it would read
    /// as untouched).
    private func placeComments(at revision: String, config: HostConnectionConfig) async -> [UUID: ReviewAnchor] {
        var placed: [UUID: ReviewAnchor] = [:]
        let live = record.comments.filter { $0.state != .dismissed && $0.side == .new }
        let byRevision = Dictionary(grouping: live, by: \.revision)
        for comment in byRevision[revision] ?? [] {
            placed[comment.id] = .moved(path: comment.path, startLine: comment.startLine, endLine: comment.endLine)
        }
        let older = byRevision.keys.filter { $0 != revision }
        let (cwd, ref) = source
        var mappings: [String: ReviewDiffResult] = [:]
        var missing: [String] = []
        for commentRevision in older {
            if let known = mappingCache[commentRevision + "|" + revision] { mappings[commentRevision] = known } else { missing.append(commentRevision) }
        }
        // A few at a time: each is an exec channel on the one SSH connection (sshd allows ~10).
        let fetched = await withTaskGroup(of: (String, ReviewDiffResult?).self) { group in
            var all: [String: ReviewDiffResult] = [:]
            var queue = missing[...]
            func start(_ commentRevision: String) {
                group.addTask {
                    let between: ReviewDiffResult? = try? await self.run(
                        TmuxCommandBuilder.reviewDiff(cwd: cwd, scope: .since, from: commentRevision, to: revision, unified: 0, ref: ref),
                        config: config
                    )
                    return (commentRevision, between)
                }
            }
            for _ in 0..<Self.mappingConcurrency { if let next = queue.popFirst() { start(next) } }
            for await (commentRevision, between) in group {
                all[commentRevision] = between
                if let next = queue.popFirst() { start(next) }
            }
            return all
        }
        for (commentRevision, between) in fetched {
            mappings[commentRevision] = between
            // Two commits never change: the same pair always maps the same way.
            mappingCache[commentRevision + "|" + revision] = between
        }
        // A failed diff left no entry: its comments stay unplaced.
        for (commentRevision, between) in mappings {
            let mapping = UnifiedDiff(parsing: between.patch)
            for comment in byRevision[commentRevision] ?? [] {
                if between.truncated, mapping.file(fromOldPath: comment.path) == nil { continue }
                placed[comment.id] = ReviewAnchor.resolve(comment, through: mapping)
            }
        }
        return placed
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
                // `path` is the file's old path for removed lines (they're in the old revision).
                return side == .old && comment.revision == result?.from && comment.path == path
                    && (comment.endLine ?? comment.startLine) == line
            }
            guard side == .new, case let .moved(movedPath, start, end)? = anchors[comment.id], let start else { return false }
            return movedPath == path && (end ?? start) == line
        }
    }

    /// Comments of a file that aren't on a line of the diff on screen: whole-file ones, ones on
    /// lines the diff doesn't show, and ones whose lines changed since.
    func otherComments(file: DiffFile) -> [ReviewComment] {
        let path = file.path
        let oldPath = file.oldPath ?? file.path
        let shownNew = Set(file.hunks.flatMap(\.lines).compactMap { $0.kind == .removed ? nil : $0.newLine })
        let shownOld = Set(file.hunks.flatMap(\.lines).compactMap { $0.kind == .removed ? $0.oldLine : nil })
        return record.comments.filter { comment in
            guard comment.state != .dismissed else { return false }
            if comment.side == .old {
                guard comment.path == oldPath else { return false }
                return comment.revision != result?.from || !shownOld.contains(comment.endLine ?? comment.startLine ?? -1)
            }
            switch anchors[comment.id] {
            case let .moved(movedPath, start, end)?:
                guard movedPath == path else { return false }
                guard let start else { return true }
                return !shownNew.contains(end ?? start)
            case .stale?, nil:
                // Not followed to this revision: under the name it had, which a rename changed.
                return comment.path == path || comment.path == file.oldPath
            }
        }
    }

    func isStale(_ comment: ReviewComment) -> Bool {
        if comment.side == .old { return comment.revision != result?.from }
        return anchors[comment.id] == .stale
    }

    /// Comments not tied to any file in this diff (their file has no changes in this scope).
    func commentsOutsideDiff() -> [ReviewComment] {
        let paths = Set(diff.files.map(\.path) + diff.files.compactMap(\.oldPath))
        return record.comments.filter { comment in
            guard comment.state != .dismissed else { return false }
            if case let .moved(path, _, _)? = anchors[comment.id] { return !paths.contains(path) }
            return !paths.contains(comment.path)
        }
    }

    func commentCount(file: DiffFile) -> Int {
        record.comments.filter { comment in
            guard comment.state != .dismissed else { return false }
            if case let .moved(movedPath, _, _)? = anchors[comment.id] { return movedPath == file.path }
            return comment.path == (comment.side == .old ? file.oldPath ?? file.path : file.path)
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

    /// Drafts on another revision that couldn't be followed to the one on screen (their
    /// comparison failed or that revision is gone). Stale ones were checked and did change.
    func unchecked() -> Set<UUID> {
        Set(drafts.filter { $0.side == .new && $0.revision != result?.to && anchors[$0.id] == nil }.map(\.id))
    }

    func message() -> String {
        ReviewMessage.render(outgoing(), branch: status?.branch, revision: result?.to ?? status?.revision ?? "",
                             includesUncommitted: status.map { !$0.clean } ?? false, unchecked: unchecked())
    }

    /// Keeps the revision on the computer, types the message into the conversation, and marks
    /// the drafts sent. Nothing is marked when the message didn't go. True only when it went:
    /// a press while another send runs returns false and leaves `failure` alone.
    @discardableResult
    func send(config: HostConnectionConfig) async -> Bool {
        // Return pressed twice queues two sends before either has marked anything sent.
        guard !isSending else { return false }
        if let sendBlocker {
            failure = Failure(errorDescription: sendBlocker)
            return false
        }
        guard let revision = result?.to else { return false }
        isSending = true
        defer { isSending = false }
        let outgoing = outgoing()
        let text = message()
        do {
            let _: [String: String] = try await run(TmuxCommandBuilder.reviewKeep(cwd: source.cwd, revision: revision), config: config)
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
            return false
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
        return true
    }

    // MARK: Remote

    private func run<T: Decodable>(_ command: String, config: HostConnectionConfig) async throws -> T {
        let output = try await exec(config, command)
        switch output.exitCode {
        case TmuxCommandBuilder.reviewNoRepositoryExitCode:
            throw NotARepository()
        case TmuxCommandBuilder.reviewUnknownRevisionExitCode:
            throw Failure(errorDescription: "The changes being compared aren't on \(conversation.computer.name) any more. "
                + "Choose Uncommitted or Branch.", isUnknownRevision: true)
        case TmuxCommandBuilder.reviewGitFailedExitCode:
            // git's own words: they name the file or lock that is the problem.
            let detail = output.stderr.split(separator: "\n").first.map { $0.replacingOccurrences(of: "ai-todo-review: ", with: "") }
            throw Failure(errorDescription: "git failed in \(conversation.cwd) on \(conversation.computer.name)"
                + (detail.map { ": \(String($0.prefix(200)))" } ?? "."))
        default:
            break
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
        if error is NotARepository {
            return "\(source.cwd) on \(conversation.computer.name) isn't a git repository."
        }
        return ConversationRowActions.message(for: error, computer: conversation.computer)
    }
}
#endif
