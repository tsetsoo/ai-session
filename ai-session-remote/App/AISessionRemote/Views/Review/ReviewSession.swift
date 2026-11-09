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
        if let reviewedBranch { return (reviewedBranch.folder, reviewedBranch.branch.ref) }
        if let chosenFolder { return (chosenFolder, nil) }
        return keptBranch.map { ($0.folder, $0.branch) } ?? (conversation.cwd, nil)
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
        chosenFolder = UserDefaults.standard.string(forKey: Self.folderDefaultsKey(conversation.listKey))
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

    /// The hub store's offline state (the window keeps it current): reviews are read-only
    /// while it is set.
    var hubOffline = false

    /// Reviews are read-only while the hub can't be reached: what changes here couldn't be
    /// kept where the phone and other Macs see it.
    static let offlineMessage = "The hub can't be reached, so reviews are read-only until it's back."

    /// Why Send is off, or nil.
    var sendBlocker: String? {
        if hubOffline { return Self.offlineMessage }
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
        lastConfig = config
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
        case .pullRequest where selectedPullRequest == nil:
            self.scope = .uncommitted
            return
        case .uncommitted where keptBranch != nil || reviewedBranch != nil:
            // A branch on its own has nothing uncommitted; what it has is on the branch.
            self.scope = .branch
            return
        case .uncommitted, .branch, .conversation, .pullRequest:
            break
        }
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        // The hub's copy first: comments and findings from the phone or another Mac.
        await store.refresh(key)
        guard generation == loadGeneration else { return }
        let knownAtStart = Set(record.comments.map(\.id))
        do {
            let status = try await locate(config: config)
            guard generation == loadGeneration else { return }
            if keptBranch != nil || reviewedBranch != nil, scope == .uncommitted {
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
            var to = status.revision
            if scope == .pullRequest, let number = selectedPullRequest {
                // Exactly the PR's changes, from origin: wherever the agent worked on it.
                let item = pullRequests?.prs.first { $0.number == number }
                let fetched: ReviewPullRequestFetch = try await run(
                    TmuxCommandBuilder.reviewFetchPullRequest(cwd: cwd, number: number, base: item?.baseRef, head: item?.headSHA),
                    config: config
                )
                guard generation == loadGeneration else { return }
                from = fetched.base
                to = fetched.head
            }
            let result: ReviewDiffResult = try await run(
                TmuxCommandBuilder.reviewDiff(cwd: cwd, scope: scope, from: from, to: to, ref: ref),
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
    @ObservationIgnored private var lastConfig: HostConnectionConfig?

    /// The conversation's folder when it is in git. When it isn't: the kept branch of its
    /// worktree in the project folder, or a failure that says why there's nothing to review.
    private func locate(config: HostConnectionConfig) async throws -> ReviewStatus {
        if let reviewedBranch {
            do {
                return try await run(TmuxCommandBuilder.reviewStatus(cwd: reviewedBranch.folder, ref: reviewedBranch.branch.ref), config: config)
            } catch let failure as Failure where failure.isUnknownRevision {
                throw Failure(errorDescription: "The branch \(reviewedBranch.branch.name) isn't on \(conversation.computer.name) any more, "
                    + "nor on its origin as last fetched.")
            }
        }
        if let chosenFolder {
            do {
                let status: ReviewStatus = try await run(TmuxCommandBuilder.reviewStatus(cwd: chosenFolder), config: config)
                keptBranch = nil
                return status
            } catch is NotARepository {
                // Kept: it may be back. The menu has the conversation's folder and the others.
                throw Failure(errorDescription: "The worktree \(chosenFolder) isn't on \(conversation.computer.name) any more. "
                    + "Choose another under Reviewing, or this conversation's folder.")
            }
        }
        do {
            let status: ReviewStatus = try await run(TmuxCommandBuilder.reviewStatus(cwd: conversation.cwd), config: config)
            keptBranch = nil
            conversationRoot = status.root
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
        userChose = true
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
        guard editable(), let result else { return }
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
        guard editable() else { return }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.update(key) { record in
            if let index = record.comments.firstIndex(where: { $0.id == id && ($0.state == .draft || $0.state == .new) }) {
                record.comments[index].body = text
            }
        }
    }

    func deleteComment(_ id: UUID) {
        guard editable() else { return }
        store.update(key) { $0.comments.removeAll { $0.id == id && $0.state == .draft } }
        anchors[id] = nil
    }

    /// Hides a sent comment or a finding from the diff; a sent one stays in the batch's
    /// history, a finding stays known so a later review doesn't bring it back.
    func dismissComment(_ id: UUID) {
        guard editable() else { return }
        store.update(key) { record in
            if let index = record.comments.firstIndex(where: { $0.id == id }) { record.comments[index].state = .dismissed }
        }
        anchors[id] = nil
    }

    /// False, with the reason shown, while the hub is offline.
    private func editable() -> Bool {
        guard hubOffline else { return true }
        failure = Failure(errorDescription: Self.offlineMessage)
        return false
    }

    /// The hub's newer copy of this conversation's review (another device changed it).
    func refreshFromHub() async {
        await store.refresh(key)
    }

    // MARK: Findings

    /// A reviewer's finding joins the next batch (Send), or leaves it again.
    func queueFinding(_ id: UUID, _ queued: Bool = true) {
        guard editable() else { return }
        store.update(key) { record in
            guard let index = record.comments.firstIndex(where: { $0.id == id }),
                  record.comments[index].isFinding,
                  queued ? [.new, .stale].contains(record.comments[index].state) : record.comments[index].state == .draft
            else { return }
            record.comments[index].state = queued ? .draft : .new
        }
    }

    /// A dismissed finding back in the list. It is placed again by the next load unless its
    /// lines are on the revision on screen.
    func restoreFinding(_ id: UUID) {
        guard editable() else { return }
        store.update(key) { record in
            guard let index = record.comments.firstIndex(where: { $0.id == id && $0.state == .dismissed }),
                  record.comments[index].isFinding else { return }
            record.comments[index].state = .new
        }
        if let comment = record.comments.first(where: { $0.id == id }), comment.side == .new {
            if comment.revision == result?.to {
                anchors[id] = .moved(path: comment.path, startLine: comment.startLine, endLine: comment.endLine)
            } else {
                placeUnplaced()
            }
        }
    }

    /// Places comments that have no anchor yet (new findings from an older revision, restored
    /// ones) in the diff on screen, without reloading it. Mappings already fetched are reused.
    private func placeUnplaced() {
        guard let config = lastConfig, let revision = result?.to else { return }
        let generation = loadGeneration
        Task {
            let placed = await placeComments(at: revision, config: config)
            // A load since then placed everything itself.
            guard generation == loadGeneration, result?.to == revision else { return }
            for (id, anchor) in placed where anchors[id] == nil { anchors[id] = anchor }
        }
    }

    enum FindingFilter: String, CaseIterable, Identifiable {
        case new, sent, stale, dismissed
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// The reviewers' findings under one filter, highest severity first, then by place.
    /// New: not acted on yet, or picked for the next batch. Stale: unsent ones whose lines
    /// changed since the review.
    func findings(_ filter: FindingFilter) -> [ReviewComment] {
        record.comments.filter { comment in
            guard comment.isFinding else { return false }
            switch filter {
            case .new: return comment.state.isOpen && comment.state != .stale && !isStale(comment)
            case .stale: return comment.state == .stale || (comment.state.isOpen && isStale(comment))
            case .sent: return comment.state.wasSent
            case .dismissed: return comment.state == .dismissed
            }
        }
        .sorted {
            (ReviewFindings.rank($0.severity), $0.path, $0.startLine ?? 0) < (ReviewFindings.rank($1.severity), $1.path, $1.startLine ?? 0)
        }
    }

    /// Where a finding is in the diff on screen: its file there, and its last line (on its
    /// side), or nil when it isn't shown on a line.
    func place(of comment: ReviewComment) -> (path: String, side: DiffSide, line: Int?) {
        if comment.side == .new, case let .moved(path, start, end)? = anchors[comment.id] {
            return (path, .new, start.map { end ?? $0 })
        }
        let line = comment.side == .old && comment.revision == result?.from ? comment.endLine ?? comment.startLine : nil
        return (comment.path, comment.side, line)
    }

    /// New-side lines of `file` that unsent findings are about, with the highest severity on each.
    func findingMarks(file: DiffFile) -> [Int: String] {
        var marks: [Int: String] = [:]
        for comment in record.comments where comment.isFinding && comment.state.isOpen {
            guard comment.side == .new, case let .moved(path, start?, end)? = anchors[comment.id], path == file.path else { continue }
            for line in start...max(start, end ?? start) {
                let severity = comment.severity ?? "medium"
                if let current = marks[line], ReviewFindings.rank(current) <= ReviewFindings.rank(severity) { continue }
                marks[line] = severity
            }
        }
        return marks
    }

    // MARK: The user's pull requests

    /// The PRs/MRs the computer's gh/glab account opened in this repository, newest first.
    private(set) var pullRequests: ReviewPullRequestList?
    /// The computer's `ai-todo-review` is too old for what the window asks of it.
    private(set) var helperProblem: String?
    /// The PR/MR shown in the Pull Request scope.
    private(set) var selectedPullRequest: Int?
    /// The user picked something themselves: the window doesn't pick a PR for them any more.
    @ObservationIgnored private var userChose = false

    /// Shows exactly this PR's changes.
    func open(pullRequest number: Int, byUser: Bool = true) {
        if byUser { userChose = true }
        guard selectedPullRequest != number || scope != .pullRequest || reviewedBranch != nil else { return }
        reviewedBranch = nil
        selectedPullRequest = number
        pullRequest = nil
        scope = .pullRequest
    }

    /// A branch the conversation made or pushed, with no PR: what it has that the default
    /// branch doesn't, read from the repository (no checkout needed).
    private(set) var reviewedBranch: (folder: String, branch: ReviewPullRequestList.Branch)?

    func open(branch: ReviewPullRequestList.Branch, byUser: Bool = true) {
        if byUser { userChose = true }
        // Checked out somewhere: that worktree, so what isn't committed yet shows too.
        if let worktree = worktrees.first(where: { $0.branch == branch.name }) {
            show(folder: worktree.path)
            if scope != .branch { scope = .branch }
            return
        }
        if reviewedBranch?.branch.name == branch.name, scope == .branch {
            reviewedBranch?.branch = branch  // newer `at`/`pushed`: same tree, nothing to reload
            return
        }
        // In the folder on screen: any worktree of the repository can read any of its branches.
        reviewedBranch = (folder, branch)
        selectedPullRequest = nil
        pullRequest = nil
        status = nil
        result = nil
        diff = UnifiedDiff(files: [])
        anchors = [:]
        scope = .branch
    }

    /// A scope picked in the window (not a PR).
    func pick(scope: ReviewScope) {
        userChose = true
        // Off the PR: its header mustn't stay for Publish or Merge on the branch.
        if self.scope == .pullRequest, scope != .pullRequest { pullRequest = nil }
        self.scope = scope
    }

    /// Lists the user's PRs/MRs; opens the likely one (linked by the runner, or the only one
    /// updated since the conversation began) unless the user already chose what to look at.
    func loadPullRequests(config: HostConnectionConfig) async {
        let asked = folder
        let since = Self.gitTime(conversation.createdAt)
        guard var output = try? await exec(config, TmuxCommandBuilder.reviewPullRequests(
            cwd: asked, since: since, tool: conversation.tool, sessionID: conversation.sessionId)),
              asked == folder else { return }
        if output.exitCode == 64 {
            // A helper from before `--session`: the account's PRs, without the conversation's own.
            guard let plain = try? await exec(config, TmuxCommandBuilder.reviewPullRequests(cwd: asked, since: since)),
                  asked == folder else { return }
            output = plain
        }
        // 64: a helper from before `prs`, or 127: none at all. Said, not silently empty.
        if output.exitCode == 64 || output.exitCode == 127 {
            helperProblem = "The review helper on \(conversation.computer.name) is older than this app, so it can't list pull requests. "
                + "Reinstall the host scripts there (scripts/todo/install.sh)."
            return
        }
        guard let list: ReviewPullRequestList = try? await decode(output) else { return }
        helperProblem = nil
        pullRequests = list
        openLikelyPullRequest()
    }

    /// Opens the conversation's PR when it's clear which that is (see `likely`), once the
    /// list and the worktrees are in, unless the user chose what to look at.
    private func openLikelyPullRequest() {
        guard !userChose, selectedPullRequest == nil, reviewedBranch == nil, worktreesLoaded, let list = pullRequests else { return }
        var branches = Set(worktrees.filter(\.changedSince).compactMap(\.branch))
        if chosenFolder == nil, let branch = status?.branch { branches.insert(branch) }
        switch list.target(linkedURL: conversation.pullRequest?.url, agentBranches: branches) {
        case .pullRequest(let number)?: open(pullRequest: number, byUser: false)
        case .branch(let branch)?: open(branch: branch, byUser: false)
        case nil: break
        }
    }

    // MARK: Which worktree

    /// A worktree of the repository picked in the window instead of the conversation's folder
    /// (an agent that made its own), remembered per conversation on this device.
    private(set) var chosenFolder: String?
    /// The repository's worktrees, most recently active first; from the last load.
    private(set) var worktrees: [ReviewWorktrees.Worktree] = []
    /// The worktrees were read once (or failed to be): the window may open something by itself.
    @ObservationIgnored private var worktreesLoaded = false

    private static func folderDefaultsKey(_ key: String) -> String { "review.folder.\(key)" }

    /// The conversation's own repository root, from a load of its folder.
    private var conversationRoot: String?

    /// Other conversations' folders on this computer (the window keeps it current): their
    /// worktrees aren't this agent's, so they aren't suggested.
    var otherConversationFolders: [String] = []

    /// `path` is one of `folders`, written as given or with `~` for the home folder.
    static func matches(_ path: String, _ folders: [String]) -> Bool {
        folders.contains { folder in
            folder == path || (folder.hasPrefix("~/") && path.hasSuffix(String(folder.dropFirst(1))))
        }
    }

    /// The folder on screen: the chosen worktree, the kept branch's project folder, or the
    /// conversation's own.
    var folder: String { source.cwd }

    /// Reviews `folder` (a worktree of the same repository) from now on; nil: the
    /// conversation's own folder again. The window's reload follows.
    func choose(folder: String?) {
        userChose = true
        show(folder: folder)
    }

    /// Reviews `folder` (nil: the conversation's own); for the user's pick and for opening a
    /// branch that's checked out there.
    private func show(folder: String?) {
        let folder = folder.flatMap { $0 == conversationRoot || Self.matches($0, [conversation.cwd]) ? nil : $0 }
        let leftBranch = reviewedBranch != nil
        reviewedBranch = nil
        guard folder != chosenFolder else {
            if leftBranch {
                pullRequest = nil
                status = nil
                result = nil
                diff = UnifiedDiff(files: [])
                anchors = [:]
                if scope == .branch { scope = .uncommitted }
            }
            return
        }
        chosenFolder = folder
        UserDefaults.standard.set(folder, forKey: Self.folderDefaultsKey(key))
        // Another tree: nothing on screen belongs to it.
        status = nil
        result = nil
        diff = UnifiedDiff(files: [])
        anchors = [:]
        pullRequest = nil
        pullRequests = nil
        selectedPullRequest = nil
        commits = []
        mappingCache = [:]
        if scope == .since || scope == .commit || scope == .pullRequest { scope = .uncommitted }
        baseCommit = nil
    }

    /// Lists the repository's worktrees, marking those active since the conversation began.
    func loadWorktrees(config: HostConnectionConfig) async {
        let since = Self.gitTime(conversation.createdAt)
        let asked = folder
        let found: ReviewWorktrees? = try? await run(TmuxCommandBuilder.reviewWorktrees(cwd: asked, since: since), config: config)
        // Another folder was chosen meanwhile: its own load follows.
        guard asked == folder else { return }
        if let found { worktrees = found.worktrees }
        // Failed too: the PR list alone still decides.
        worktreesLoaded = true
        openLikelyPullRequest()
    }

    /// Worktrees other than the one on screen that changed since the conversation began:
    /// where its agent may really be working. Offered while the window shows the
    /// conversation's own folder.
    var suggestedWorktrees: [ReviewWorktrees.Worktree] {
        guard chosenFolder == nil else { return [] }
        let here = status?.root ?? conversation.cwd
        return Array(worktrees.filter {
            $0.changedSince && !$0.current && $0.path != here && !Self.matches($0.path, otherConversationFolders)
        }.prefix(3))
    }

    // MARK: Pull / merge request

    /// The branch's PR/MR from the computer's gh or glab, after the last load. Nil: not asked yet.
    private(set) var pullRequest: ReviewPullRequestInfo?

    /// Reads the PR/MR and its review threads (read-only) and adds the open threads on lines
    /// as items. Quiet on failure: local review doesn't depend on it. One at a time.
    func loadPullRequest(config: HostConnectionConfig) async {
        let (cwd, ref) = source
        // The newest read wins: one for another PR or folder replaces any still running.
        pullRequestGeneration += 1
        let generation = pullRequestGeneration
        let number = scope == .pullRequest ? selectedPullRequest : nil
        guard let info: ReviewPullRequestInfo = try? await run(
            TmuxCommandBuilder.reviewPullRequest(cwd: cwd, ref: number == nil ? ref : nil, number: number), config: config
        ),
              generation == pullRequestGeneration, cwd == folder, ref == source.ref
        else { return }
        pullRequest = info
        guard info.access, let pr = info.pr else { return }
        guard let threads: ReviewThreadsResult = try? await run(
            TmuxCommandBuilder.reviewThreads(cwd: cwd, ref: ref, number: pr.number, url: pr.url, projectID: pr.projectID),
            config: config
        ), threads.access, !threads.threads.isEmpty, generation == pullRequestGeneration, !hubOffline, cwd == folder,
              ref == source.ref else { return }
        let fallback = pr.headSHA ?? result?.to ?? ""
        // On the record as it is now: it may have changed during the lookups.
        store.update(key) { record in
            _ = ReviewThreadItems.apply(threads, provider: info.provider, fallbackRevision: fallback,
                                        conversationKey: key, to: &record.comments)
        }
        // On the revision on screen: placed now. Older ones: worked out from their revision.
        var older = false
        for comment in record.comments where comment.isFinding && comment.state.isOpen && comment.side == .new && anchors[comment.id] == nil {
            if comment.revision == result?.to {
                anchors[comment.id] = .moved(path: comment.path, startLine: comment.startLine, endLine: comment.endLine)
            } else {
                older = true
            }
        }
        if older { placeUnplaced() }
    }

    @ObservationIgnored private var pullRequestGeneration = 0

    // MARK: Publishing to the PR/MR (each confirmed in the window)

    private(set) var isWriting = false

    private var openPullRequest: ReviewPullRequestInfo.PullRequest? {
        guard let info = pullRequest, info.access, let pr = info.pr, pr.state == "open" else { return nil }
        return pr
    }

    /// The PR/MR's head is what the worktree has, committed and pushed.
    private var headBlocker: String? {
        guard let pr = openPullRequest else { return "There's no open pull/merge request for this branch." }
        guard let status else { return "Load the changes first." }
        guard pr.headSHA != nil else { return "GitHub or GitLab didn't say which commit the pull request is at. Refresh." }
        if scope == .pullRequest {
            // The PR's own head, fetched: nothing local has to match.
            return result?.to == pr.headSHA ? nil : "The pull request moved on since this was loaded. Refresh."
        }
        if keptBranch == nil, reviewedBranch == nil, !status.clean { return "There are uncommitted changes. Only committed, pushed lines can be published." }
        if let ahead = status.ahead, ahead > 0 { return "\(ahead) commit\(ahead == 1 ? " isn't" : "s aren't") pushed yet." }
        if let head = pr.headSHA, head != status.head {
            return "The pull request is at \(head.prefix(7)) and the worktree at \((status.head ?? "").prefix(7)). Push or pull first."
        }
        return nil
    }

    /// Why Publish is off, or nil. Its comments are on the PR's own lines: Branch scope at its head.
    var publishBlocker: String? {
        if hubOffline { return Self.offlineMessage }
        if let headBlocker { return headBlocker }
        if scope != .branch, scope != .pullRequest {
            return "Pick the pull request (or Branch): a review comments on its own changes."
        }
        return nil
    }

    /// Why Approve is off (nil: on); hidden altogether on the user's own PR (`canApprove`).
    var approveBlocker: String? { headBlocker }

    var canApprove: Bool {
        guard let info = pullRequest, let pr = info.pr else { return false }
        return pr.author == nil || pr.author != info.viewer
    }

    /// Why Merge is off, or nil. Pending or failing checks block it unless `overrideChecks`.
    func mergeBlocker(overrideChecks: Bool) -> String? {
        if let headBlocker { return headBlocker }
        guard let pr = openPullRequest else { return nil }
        if pr.draft { return "It's a draft." }
        if !overrideChecks {
            switch pr.checks.state {
            case "failing": return "Checks are failing. Hold Option to merge anyway."
            case "pending": return "Checks are still running. Hold Option to merge anyway."
            default: break
            }
        }
        return nil
    }

    /// A comment that can go on a line of the PR's diff, or why not.
    struct PublishCandidate: Identifiable {
        let comment: ReviewComment
        let line: (start: Int, end: Int)?
        let reason: String?
        var id: UUID { comment.id }
    }

    /// The user's comments and the reviewers' findings that aren't dismissed (PR threads are
    /// already there), each with the lines it would be published on.
    func publishCandidates() -> [PublishCandidate] {
        record.comments.filter { $0.state != .dismissed && $0.prAuthor == nil }.map { comment in
            guard let start = comment.startLine else {
                return PublishCandidate(comment: comment, line: nil, reason: "On the whole file: goes in the summary.")
            }
            if comment.side == .old {
                guard comment.revision == result?.from,
                      let file = diff.files.first(where: { ($0.oldPath ?? $0.path) == comment.path }),
                      Self.shown(file, side: .old, start...(comment.endLine ?? start))
                else { return PublishCandidate(comment: comment, line: nil, reason: "Those removed lines aren't in this diff.") }
                return PublishCandidate(comment: comment, line: (start, comment.endLine ?? start), reason: nil)
            }
            guard case let .moved(path, movedStart?, movedEnd)? = anchors[comment.id] else {
                return PublishCandidate(comment: comment, line: nil, reason: "Its lines changed since.")
            }
            let end = movedEnd ?? movedStart
            guard let file = diff.files.first(where: { $0.path == path }),
                  Self.shown(file, side: .new, movedStart...end)
            else { return PublishCandidate(comment: comment, line: nil, reason: "Its lines aren't in the pull request's changes.") }
            return PublishCandidate(comment: comment, line: (movedStart, end), reason: nil)
        }
    }

    /// Every line of the range is in the file's hunks (GitHub and GitLab take only those).
    private static func shown(_ file: DiffFile, side: DiffSide, _ lines: ClosedRange<Int>) -> Bool {
        let numbers = Set(file.hunks.flatMap(\.lines).compactMap { line in
            side == .old ? (line.kind == .removed || line.kind == .context ? line.oldLine : nil) : (line.kind == .removed ? nil : line.newLine)
        })
        return lines.allSatisfy(numbers.contains)
    }

    /// Posts a review as the computer's gh/glab account. Whole-file comments go in the summary.
    @discardableResult
    func publish(event: ReviewPublishRequest.Event, summary: String, ids: Set<UUID>, config: HostConnectionConfig) async -> Bool {
        guard !isWriting, let pr = openPullRequest, let head = pr.headSHA else { return false }
        if event != .approve, let publishBlocker {
            failure = Failure(errorDescription: publishBlocker)
            return false
        }
        if event == .approve, let approveBlocker {
            failure = Failure(errorDescription: approveBlocker)
            return false
        }
        let chosen = publishCandidates().filter { ids.contains($0.id) }
        var comments: [ReviewPublishRequest.Comment] = []
        var fileNotes: [String] = []
        for candidate in chosen {
            let comment = candidate.comment
            let body = [comment.title, comment.body].compactMap { $0 }.joined(separator: "\n\n")
            if let line = candidate.line {
                if comment.side == .old {
                    // Removed lines: the file as the PR names it now, and its name at the base.
                    let file = diff.files.first { ($0.oldPath ?? $0.path) == comment.path }
                    comments.append(.init(path: file?.path ?? comment.path, oldPath: comment.path, side: .old,
                                          lineStart: line.start, lineEnd: line.end, body: body))
                } else {
                    let path = place(of: comment).path
                    let file = diff.files.first { $0.path == path }
                    let unchanged = file?.hunks.flatMap(\.lines).first { $0.kind == .context && $0.newLine == line.end }
                    let renamedFrom = file?.oldPath.flatMap { $0 == path ? nil : $0 }
                    comments.append(.init(path: path, oldPath: renamedFrom, side: .new, lineStart: line.start,
                                          lineEnd: line.end, oldLine: unchanged?.oldLine, body: body))
                }
            } else if comment.startLine == nil {
                fileNotes.append("**\(comment.path)**: \(body)")
            }
        }
        let text = ([summary.trimmingCharacters(in: .whitespacesAndNewlines)] + fileNotes).filter { !$0.isEmpty }.joined(separator: "\n\n")
        isWriting = true
        defer { isWriting = false }
        let (cwd, _) = source
        let review = ReviewPublishRequest(event: event, body: text, comments: comments)
        if event == .requestChanges, text.isEmpty {
            failure = Failure(errorDescription: "Request Changes needs a summary.")
            return false
        }
        if ((try? JSONEncoder().encode(review))?.count ?? 0) * 4 / 3 > TmuxCommandBuilder.reviewPublishMaxBytes {
            failure = Failure(errorDescription: "That review is too long to send in one go. Publish fewer comments at a time.")
            return false
        }
        let posted = Set(chosen.filter { $0.line != nil || $0.comment.startLine == nil }.map(\.id))
        do {
            let output = try await exec(config, TmuxCommandBuilder.reviewPublish(cwd: cwd, number: pr.number, head: head, review: review))
            if output.exitCode == TmuxCommandBuilder.reviewPartlyPublishedExitCode {
                // GitLab took the comments but a later step failed: they're up, don't post them twice.
                markPublished(posted)
            }
            try writeOutcome(output)
        } catch {
            failure = Failure(errorDescription: message(for: error))
            return false
        }
        markPublished(posted)
        let account = pullRequest?.viewer.map { " as \($0)" } ?? ""
        notice = event == .approve && comments.isEmpty ? "Approved\(account)."
            : "Published a review with \(comments.count) comment\(comments.count == 1 ? "" : "s")\(account)."
        await loadPullRequest(config: config)
        return true
    }

    /// Merges the PR/MR, pinned to the head the window shows.
    @discardableResult
    func merge(method: String, deleteBranch: Bool, overrideChecks: Bool, config: HostConnectionConfig) async -> Bool {
        guard !isWriting, let pr = openPullRequest, let head = pr.headSHA else { return false }
        if let blocker = mergeBlocker(overrideChecks: overrideChecks) {
            failure = Failure(errorDescription: blocker)
            return false
        }
        isWriting = true
        defer { isWriting = false }
        do {
            let output = try await exec(config, TmuxCommandBuilder.reviewMerge(cwd: source.cwd, number: pr.number, head: head,
                                                                              method: method, deleteBranch: deleteBranch))
            try writeOutcome(output)
        } catch {
            failure = Failure(errorDescription: message(for: error))
            return false
        }
        notice = "Merged \(pr.name(provider: pullRequest?.provider))\(pullRequest?.viewer.map { " as \($0)" } ?? "")."
        await loadPullRequest(config: config)
        return true
    }

    /// Posted on the PR/MR: kept on the hub, so no device offers them again.
    private func markPublished(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let now = Date.now
        store.update(key) { record in
            for index in record.comments.indices where ids.contains(record.comments[index].id)
                && record.comments[index].publishedAt == nil {
                record.comments[index].publishedAt = now
            }
        }
    }

    private func writeOutcome(_ output: SSHExecResult) throws {
        let detail = output.stderr.split(separator: "\n").last.map { $0.replacingOccurrences(of: "ai-todo-review: ", with: "") }
        switch output.exitCode {
        case 0: return
        case TmuxCommandBuilder.reviewHeadMovedExitCode:
            throw Failure(errorDescription: "The pull request moved on since this review was loaded (\(detail ?? "new commits")). Refresh and look again.")
        case TmuxCommandBuilder.reviewForgeFailedExitCode, TmuxCommandBuilder.reviewPartlyPublishedExitCode,
             TmuxCommandBuilder.reviewUnknownRevisionExitCode, 64:
            throw Failure(errorDescription: detail.map { String($0.prefix(300)) } ?? "GitHub or GitLab refused it.")
        default:
            try RemoteConversations.check(output, computerName: conversation.computer.name)
        }
    }

    /// "No PR access on <computer>: gh isn't logged in", or nil.
    var pullRequestProblem: String? {
        guard let info = pullRequest, !info.access, info.provider != nil, let error = info.error else { return nil }
        return "No PR access on \(conversation.computer.name): \(error)."
    }

    // MARK: Reviewer runs

    /// The run in progress, if any.
    var activeRun: ReviewRun? {
        guard let run = record.lastRun, run.state == .running else { return nil }
        return run
    }

    /// Why Review is off, or nil.
    var reviewBlocker: String? {
        if hubOffline { return Self.offlineMessage }
        if activeRun != nil { return "A review is running." }
        guard let result else { return "Load the changes first." }
        if diff.files.isEmpty || result.from == result.to { return "There are no changes to review." }
        return nil
    }

    @ObservationIgnored var pollInterval: Duration = .seconds(3)

    /// Starts a reviewer on the changes on screen (`result.from`..`result.to`). The window's
    /// `followReview` reads how it went.
    func startReview(tool: String, brief: String?, config: HostConnectionConfig) async {
        guard reviewBlocker == nil, let result, !isStartingReview else { return }
        isStartingReview = true
        defer { isStartingReview = false }
        let run = ReviewRun(tool: tool, scope: scope.rawValue, baseSHA: result.from, reviewedSHA: result.to)
        let (cwd, ref) = source
        do {
            let output = try await exec(config, TmuxCommandBuilder.reviewRun(
                cwd: cwd, from: result.from, to: result.to, tool: tool, id: run.hostID, ref: ref, brief: brief
            ))
            if output.exitCode == TmuxCommandBuilder.reviewMissingProgramExitCode {
                let program = output.stderr.split(separator: "\n").last.map { $0.replacingOccurrences(of: " not found", with: "") } ?? tool
                throw Failure(errorDescription: "\(program) isn't installed on \(conversation.computer.name), so it can't review there.")
            }
            let _: [String: String] = try await decode(output)
        } catch {
            failure = Failure(errorDescription: message(for: error))
            return
        }
        store.update(key) { $0.runs.append(run) }
    }

    @ObservationIgnored private var isStartingReview = false

    /// Follows the running review until it ends or the caller's task is cancelled (the window
    /// closed: the run goes on on the computer, and the next window picks it up).
    func followReview(config: HostConnectionConfig) async {
        while let run = activeRun, !Task.isCancelled {
            do {
                let output = try await exec(config, TmuxCommandBuilder.reviewResult(id: run.hostID))
                if output.exitCode == TmuxCommandBuilder.reviewUnknownRevisionExitCode {
                    finishRun(run.id, ReviewRunResult(id: run.hostID, state: .failed,
                                                       error: "The review is gone from \(conversation.computer.name)."))
                    return
                }
                let state: ReviewRunResult = try await decode(output)
                reviewProblem = nil
                if state.state != .running {
                    finishRun(run.id, state)
                    return
                }
            } catch {
                // Keep trying: the computer may be asleep or the network down for a moment.
                reviewProblem = message(for: error)
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// The last failure to read a running review's state, while it is retried.
    private(set) var reviewProblem: String?

    func cancelReview(config: HostConnectionConfig) async {
        guard let active = activeRun else { return }
        do {
            let state: ReviewRunResult = try await run(TmuxCommandBuilder.reviewCancel(id: active.hostID), config: config)
            finishRun(active.id, state)
        } catch {
            failure = Failure(errorDescription: message(for: error))
        }
    }

    /// Records how a run ended and adds its new findings.
    func finishRun(_ id: UUID, _ outcome: ReviewRunResult) {
        let now = Date.now
        var added: [ReviewComment] = []
        store.update(key) { record in
            guard let index = record.runs.firstIndex(where: { $0.id == id }), record.runs[index].state == .running else { return }
            record.runs[index].state = outcome.state
            record.runs[index].finishedAt = now
            record.runs[index].error = outcome.error
            if let output = outcome.result, outcome.state == .done {
                added = ReviewFindings.comments(from: output, runID: id, existing: record.comments, at: now)
                record.runs[index].model = output.model
                record.runs[index].summary = output.summary
                record.runs[index].usage = output.usage
                record.runs[index].findingCount = output.findings.count
                record.runs[index].addedCount = added.count
                record.comments += added
            }
        }
        reviewProblem = nil
        for comment in added where comment.side == .new && comment.revision == result?.to {
            anchors[comment.id] = .moved(path: comment.path, startLine: comment.startLine, endLine: comment.endLine)
        }
        if added.contains(where: { $0.side == .new && $0.revision != result?.to }) {
            // Reviewed an older revision than the one on screen.
            placeUnplaced()
        }
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

    /// The branch named in the message: the PR's own in the Pull Request scope.
    private var messageBranch: String? {
        if scope == .pullRequest, let number = selectedPullRequest {
            return pullRequests?.prs.first { $0.number == number }?.headRef ?? pullRequest?.pr?.headRef
        }
        return status?.branch
    }

    func message() -> String {
        ReviewMessage.render(outgoing(), branch: messageBranch, revision: result?.to ?? status?.revision ?? "",
                             includesUncommitted: scope == .pullRequest ? false : status.map { !$0.clean } ?? false,
                             unchecked: unchecked())
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
        try await decode(try await exec(config, command))
    }

    private func decode<T: Decodable>(_ output: SSHExecResult) async throws -> T {
        switch output.exitCode {
        case TmuxCommandBuilder.reviewNoRepositoryExitCode:
            throw NotARepository()
        case TmuxCommandBuilder.reviewUnknownRevisionExitCode:
            throw Failure(errorDescription: "The changes being compared aren't on \(conversation.computer.name) any more. "
                + "Choose Uncommitted or Branch.", isUnknownRevision: true)
        case TmuxCommandBuilder.reviewGitFailedExitCode:
            // git's own words: they name the file or lock that is the problem.
            let detail = output.stderr.split(separator: "\n").first.map { $0.replacingOccurrences(of: "ai-todo-review: ", with: "") }
            throw Failure(errorDescription: "git failed in \(folder) on \(conversation.computer.name)"
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
