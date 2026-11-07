import Foundation

/// `ai-todo-review status`: where a conversation's worktree stands.
public struct ReviewStatus: Codable, Equatable, Sendable {
    public struct Base: Codable, Equatable, Sendable {
        /// `origin/main`, `main`, …
        public var ref: String
        public var sha: String

        public init(ref: String, sha: String) {
            self.ref = ref
            self.sha = sha
        }
    }

    public var root: String
    public var branch: String?
    public var head: String?
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var base: Base?
    /// HEAD when `clean`, else a snapshot commit of the uncommitted changes on top of it.
    public var revision: String
    public var clean: Bool
    /// The commit the runner or app made this worktree from (where its conversation began),
    /// or nil when the folder isn't such a worktree.
    public var worktreeBase: String?
    /// The branch reviewed instead of a working tree (`--ref`), or nil.
    public var ref: String?

    private enum CodingKeys: String, CodingKey {
        case root, branch, head, upstream, ahead, behind, base, revision, clean, ref
        case worktreeBase = "worktree_base"
    }

    public init(root: String, branch: String?, head: String?, upstream: String? = nil, ahead: Int? = nil,
                behind: Int? = nil, base: Base? = nil, revision: String, clean: Bool,
                worktreeBase: String? = nil, ref: String? = nil) {
        self.root = root
        self.branch = branch
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.base = base
        self.revision = revision
        self.clean = clean
        self.worktreeBase = worktreeBase
        self.ref = ref
    }
}

/// Which changes the review view shows.
public enum ReviewScope: String, Codable, CaseIterable, Sendable, Identifiable {
    /// HEAD → worktree.
    case uncommitted
    /// The last commit before the conversation started → worktree: everything since it began,
    /// committed or not, on a branch or straight on main.
    case conversation
    /// The branch's base → worktree: everything on the branch that the default branch hasn't.
    case branch
    /// The revision feedback was last sent against → worktree.
    case since
    /// A commit picked from the history → worktree.
    case commit
    /// A pull/merge request's own changes: its merge base → its head, fetched from origin.
    case pullRequest

    public var id: String { rawValue }

    /// The picker's segments; `commit` comes from the Compare With menu.
    public static let segments: [ReviewScope] = [.uncommitted, .conversation, .branch, .since]

    public var title: String {
        switch self {
        case .uncommitted: "Uncommitted"
        case .conversation: "Conversation"
        case .branch: "Branch"
        case .since: "Since Feedback"
        case .commit: "From Commit"
        case .pullRequest: "Pull Request"
        }
    }

    /// `ai-todo-review diff --scope`: the ones from a given commit are all `since --from`.
    var scriptScope: String {
        switch self {
        case .uncommitted: "uncommitted"
        case .branch: "branch"
        case .conversation, .since, .commit, .pullRequest: "since"
        }
    }
}

/// `ai-todo-review log`.
public struct ReviewLog: Codable, Equatable, Sendable {
    public struct Commit: Codable, Equatable, Sendable, Identifiable {
        public var sha: String
        public var subject: String
        /// Committer date, ISO 8601.
        public var date: String
        /// Nil without an upstream.
        public var pushed: Bool?

        public var id: String { sha }

        public init(sha: String, subject: String, date: String, pushed: Bool?) {
            self.sha = sha
            self.subject = subject
            self.date = date
            self.pushed = pushed
        }
    }

    /// Newest first, along HEAD's first parents.
    public var commits: [Commit]
    /// The last commit before `--before`, or nil (none asked, or none that old).
    public var before: String?

    public init(commits: [Commit], before: String?) {
        self.commits = commits
        self.before = before
    }
}

/// `ai-todo-review diff`.
public struct ReviewDiffResult: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var scope: String
    public var patch: String
    /// The patch was cut at a file boundary to stay under the size limit.
    public var truncated: Bool

    public init(from: String, to: String, scope: String, patch: String, truncated: Bool) {
        self.from = from
        self.to = to
        self.scope = scope
        self.patch = patch
        self.truncated = truncated
    }
}

/// Which side of a diff a comment's lines are on.
public enum DiffSide: String, Codable, Sendable {
    /// Lines of the newer revision (added or context lines).
    case new
    /// Lines only in the older revision (removed lines).
    case old
}

/// A comment on a conversation's changes: the user's own, or a reviewer agent's finding.
/// Its lines are in the file `path` as it is at `revision`; `ReviewAnchor` moves them to a
/// newer revision, or says they changed.
public struct ReviewComment: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        /// A reviewer's finding nobody has acted on: not in the next batch until Send picks it.
        case new
        case draft, sent, dismissed
        /// Hub states nothing here sets yet; kept as they are. `addressed` is a sent item the
        /// agent dealt with; `stale` an unsent one whose lines are gone.
        case addressed, stale

        /// Not sent or dismissed: still for the user to act on.
        public var isOpen: Bool { self == .new || self == .draft || self == .stale }
        /// Went to the agent.
        public var wasSent: Bool { self == .sent || self == .addressed }
    }

    public var id: UUID
    /// `user`, or a reviewer such as `reviewer:claude`.
    public var author: String
    public var path: String
    public var side: DiffSide
    /// Nil for a comment on the whole file.
    public var startLine: Int?
    public var endLine: Int?
    /// The commit the lines are in (the new side's revision, or the old side's for removed lines).
    public var revision: String
    /// The commented lines' text, quoted in the message so moved lines are still recognisable.
    public var quote: [String]
    public var body: String
    public var state: State
    public var createdAt: Date
    public var sentAt: Date?
    /// The batch it went out in.
    public var batchID: UUID?
    /// A reviewer's finding: `high` / `medium` / `low`, a one-word category, a one-line title,
    /// and the fingerprint that recognises it in a later review. Nil for the user's comments.
    public var severity: String?
    public var category: String?
    public var title: String?
    public var fingerprint: String?
    /// The review run it came from.
    public var runID: UUID?
    /// When it was posted on the PR/MR from the review window.
    public var publishedAt: Date?

    public init(id: UUID = UUID(), author: String = "user", path: String, side: DiffSide = .new,
                startLine: Int?, endLine: Int?, revision: String, quote: [String], body: String,
                state: State = .draft, createdAt: Date = .now, sentAt: Date? = nil, batchID: UUID? = nil,
                severity: String? = nil, category: String? = nil, title: String? = nil,
                fingerprint: String? = nil, runID: UUID? = nil) {
        self.id = id
        self.author = author
        self.path = path
        self.side = side
        self.startLine = startLine
        self.endLine = endLine
        self.revision = revision
        self.quote = quote
        self.body = body
        self.state = state
        self.createdAt = createdAt
        self.sentAt = sentAt
        self.batchID = batchID
        self.severity = severity
        self.category = category
        self.title = title
        self.fingerprint = fingerprint
        self.runID = runID
    }

    /// `reviewer:claude` → `claude`; nil for the user's own comments.
    public var reviewer: String? {
        author.hasPrefix(ReviewFindings.authorPrefix) ? String(author.dropFirst(ReviewFindings.authorPrefix.count)) : nil
    }

    /// `src/a.rs:12`, `src/a.rs:12-18`, or `src/a.rs`.
    public var location: String {
        guard let startLine else { return path }
        if let endLine, endLine != startLine { return "\(path):\(startLine)-\(endLine)" }
        return "\(path):\(startLine)"
    }
}

/// One "Send to agent": which comments went, against which revision, when.
public struct ReviewBatch: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var commentIDs: [UUID]
    /// The worktree's revision when it was sent (kept on the computer with `ai-todo-review keep`).
    public var revision: String
    public var sentAt: Date
    /// The conversation's status revision then: a later idle turn is the agent's answer.
    public var statusRevision: Int?

    public init(id: UUID = UUID(), commentIDs: [UUID], revision: String, sentAt: Date = .now, statusRevision: Int? = nil) {
        self.id = id
        self.commentIDs = commentIDs
        self.revision = revision
        self.sentAt = sentAt
        self.statusRevision = statusRevision
    }
}

/// Everything the review view keeps for one conversation.
public struct ReviewRecord: Codable, Equatable, Sendable {
    public var comments: [ReviewComment]
    public var batches: [ReviewBatch]
    /// Reviewer agent runs, oldest first.
    public var runs: [ReviewRun]

    public init(comments: [ReviewComment] = [], batches: [ReviewBatch] = [], runs: [ReviewRun] = []) {
        self.comments = comments
        self.batches = batches
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey { case comments, batches, runs }

    /// Files written before reviewer runs existed have no `runs`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comments = try container.decode([ReviewComment].self, forKey: .comments)
        batches = try container.decode([ReviewBatch].self, forKey: .batches)
        runs = try container.decodeIfPresent([ReviewRun].self, forKey: .runs) ?? []
    }

    public var drafts: [ReviewComment] { comments.filter { $0.state == .draft } }
    public var lastBatch: ReviewBatch? { batches.max { $0.sentAt < $1.sentAt } }
    public var lastRun: ReviewRun? { runs.max { $0.startedAt < $1.startedAt } }
}

/// `ai-todo-review worktrees`: the repository's worktrees, most recently active first. For a
/// conversation whose agent made a worktree of its own outside the conversation's folder.
public struct ReviewWorktrees: Codable, Equatable, Sendable {
    public struct Worktree: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        public var branch: String?
        public var head: String?
        public var detached: Bool
        /// The folder the command was run in.
        public var current: Bool
        /// The later of its last commit and its index's last change, ISO 8601.
        public var activeAt: String?
        /// Active since the conversation began.
        public var changedSince: Bool

        public var id: String { path }

        private enum CodingKeys: String, CodingKey {
            case path, branch, head, detached, current
            case activeAt = "active_at", changedSince = "changed_since"
        }

        public init(path: String, branch: String?, head: String? = nil, detached: Bool = false, current: Bool = false,
                    activeAt: String? = nil, changedSince: Bool = false) {
            self.path = path
            self.branch = branch
            self.head = head
            self.detached = detached
            self.current = current
            self.activeAt = activeAt
            self.changedSince = changedSince
        }

        /// `codex/ein-13514-local-create-fk`, or the folder's name when detached.
        public var name: String { branch ?? (path as NSString).lastPathComponent }
    }

    public var root: String
    public var worktrees: [Worktree]

    public init(root: String, worktrees: [Worktree]) {
        self.root = root
        self.worktrees = worktrees
    }
}

/// `ai-todo-review prs`: the PRs/MRs the computer's gh/glab account opened, newest first.
public struct ReviewPullRequestList: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var number: Int
        public var title: String
        public var url: String?
        /// `open`, `merged` or `closed`.
        public var state: String
        public var draft: Bool
        public var headRef: String?
        public var baseRef: String?
        public var headSHA: String?
        public var updatedAt: String?
        /// Updated since the conversation began.
        public var since: Bool

        public var id: Int { number }

        private enum CodingKeys: String, CodingKey {
            case number, title, url, state, draft, since
            case headRef = "head_ref", baseRef = "base_ref", headSHA = "head_sha", updatedAt = "updated_at"
        }

        public init(number: Int, title: String, url: String? = nil, state: String = "open", draft: Bool = false,
                    headRef: String? = nil, baseRef: String? = nil, headSHA: String? = nil, updatedAt: String? = nil,
                    since: Bool = false) {
            self.number = number
            self.title = title
            self.url = url
            self.state = state
            self.draft = draft
            self.headRef = headRef
            self.baseRef = baseRef
            self.headSHA = headSHA
            self.updatedAt = updatedAt
            self.since = since
        }
    }

    public var provider: String?
    public var access: Bool
    public var error: String?
    public var viewer: String?
    public var prs: [Item]

    public init(provider: String?, access: Bool, error: String? = nil, viewer: String? = nil, prs: [Item]) {
        self.provider = provider
        self.access = access
        self.error = error
        self.viewer = viewer
        self.prs = prs
    }

    /// The PR to open the window on: the only one updated since the conversation began, or
    /// the one the runner linked to it. Nil when that's not clear.
    public func likely(linkedURL: String?) -> Item? {
        if let linkedURL, let linked = prs.first(where: { $0.url == linkedURL }) { return linked }
        let recent = prs.filter(\.since)
        return recent.count == 1 ? recent[0] : nil
    }
}

/// `ai-todo-review fetch-pr`: a PR's head and the merge base with its base branch.
public struct ReviewPullRequestFetch: Codable, Equatable, Sendable {
    public var number: Int
    public var head: String
    public var base: String
    public var baseRef: String

    private enum CodingKeys: String, CodingKey {
        case number, head, base
        case baseRef = "base_ref"
    }

    public init(number: Int, head: String, base: String, baseRef: String) {
        self.number = number
        self.head = head
        self.base = base
        self.baseRef = baseRef
    }
}
