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
        }
    }

    /// `ai-todo-review diff --scope`: the ones from a given commit are all `since --from`.
    var scriptScope: String {
        switch self {
        case .uncommitted: "uncommitted"
        case .branch: "branch"
        case .conversation, .since, .commit: "since"
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

/// A comment on a conversation's changes: the user's own, or later a reviewer's finding.
/// Its lines are in the file `path` as it is at `revision`; `ReviewAnchor` moves them to a
/// newer revision, or says they changed.
public struct ReviewComment: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case draft, sent, dismissed
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

    public init(id: UUID = UUID(), author: String = "user", path: String, side: DiffSide = .new,
                startLine: Int?, endLine: Int?, revision: String, quote: [String], body: String,
                state: State = .draft, createdAt: Date = .now, sentAt: Date? = nil, batchID: UUID? = nil) {
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

    public init(comments: [ReviewComment] = [], batches: [ReviewBatch] = []) {
        self.comments = comments
        self.batches = batches
    }

    public var drafts: [ReviewComment] { comments.filter { $0.state == .draft } }
    public var lastBatch: ReviewBatch? { batches.max { $0.sentAt < $1.sentAt } }
}
