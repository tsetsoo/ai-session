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
        /// Source repository identity; a fork can reuse a local branch’s name.
        public var headRepository: String?
        public var updatedAt: String?
        /// Updated since the conversation began.
        public var since: Bool
        /// What the conversation did with it, from its transcript: `created`, `changed` (pushed
        /// to it, edited, commented, merged) or `read`. Nil: nothing, or no transcript.
        public var mine: String?
        /// When it last did (ISO 8601).
        public var mineAt: String?

        public var id: Int { number }
        /// The conversation made it or worked on it.
        public var isMine: Bool { mine == "created" || mine == "changed" }
        public var comparisonKey: String { "\(number):\(state):\(baseRef ?? ""):\(headSHA ?? ""):\(headRepository ?? "")" }

        private enum CodingKeys: String, CodingKey {
            case number, title, url, state, draft, since, mine
            case headRef = "head_ref", baseRef = "base_ref", headSHA = "head_sha", updatedAt = "updated_at", mineAt = "mine_at"
            case headRepository = "head_repository"
        }

        public init(number: Int, title: String, url: String? = nil, state: String = "open", draft: Bool = false,
                    headRef: String? = nil, baseRef: String? = nil, headSHA: String? = nil, updatedAt: String? = nil,
                    since: Bool = false, mine: String? = nil, mineAt: String? = nil, headRepository: String? = nil) {
            self.number = number
            self.title = title
            self.url = url
            self.state = state
            self.draft = draft
            self.headRef = headRef
            self.baseRef = baseRef
            self.headSHA = headSHA
            self.headRepository = headRepository
            self.updatedAt = updatedAt
            self.since = since
            self.mine = mine
            self.mineAt = mineAt
        }
    }

    /// A branch the conversation made or pushed in this repository that no listed PR is from.
    public struct Branch: Codable, Equatable, Sendable, Identifiable, Hashable {
        public var name: String
        /// What `--ref` takes: the local branch, else `origin/<name>`.
        public var ref: String
        public var pushed: Bool
        /// When the conversation last made or pushed it (ISO 8601).
        public var at: String?

        public var id: String { name }

        public init(name: String, ref: String? = nil, pushed: Bool = false, at: String? = nil) {
            self.name = name
            self.ref = ref ?? name
            self.pushed = pushed
            self.at = at
        }
    }

    public var provider: String?
    public var access: Bool
    public var error: String?
    public var viewer: String?
    public var prs: [Item]
    /// Nil from helpers that don't read transcripts, or when none was asked for.
    public var branches: [Branch]?
    /// Branches actually created or pushed by this conversation, including merged branches
    /// and those with a PR. Unlike `branches`, this is ownership evidence, not a diff list.
    public var workBranches: [Branch]?
    public var defaultBranch: String?
    public var repository: String?

    private enum CodingKeys: String, CodingKey {
        case provider, access, error, viewer, prs, branches, transcript, repository
        case workBranches = "work_branches", defaultBranch = "default_branch"
    }

    /// The conversation's transcript was found on the computer (nil: not asked, or an older helper).
    public var transcript: Bool?

    public init(provider: String?, access: Bool, error: String? = nil, viewer: String? = nil, prs: [Item],
                branches: [Branch]? = nil, transcript: Bool? = nil, workBranches: [Branch]? = nil, defaultBranch: String? = nil, repository: String? = nil) {
        self.provider = provider
        self.access = access
        self.error = error
        self.viewer = viewer
        self.prs = prs
        self.branches = branches
        self.transcript = transcript
        self.workBranches = workBranches
        self.defaultBranch = defaultBranch
        self.repository = repository
    }

    /// What the window opens on by itself.
    public enum Target: Equatable, Sendable {
        case pullRequest(Int)
        case branch(Branch)
        case worktree(ReviewWorktrees.Worktree)
    }

    /// Match remote home paths and macOS's /tmp alias without using this device's home.
    public static func sameFolder(_ path: String, _ folder: String) -> Bool {
        func normalized(_ value: String) -> String {
            var path = value
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return path.hasPrefix("/private/tmp/") ? String(path.dropFirst(8)) : path
        }
        let path = normalized(path), folder = normalized(folder)
        if path == folder { return true }
        return folder.hasPrefix("~/") && path.hasSuffix(String(folder.dropFirst(1)))
    }

    private static func activity(_ value: String?) -> Date {
        value.flatMap(ReviewSync.date(from:)) ?? .distantPast
    }

    /// Proven branches, newest actual branch activity first. Old helpers can still prove
    /// ownership through a created PR; a comment or merge on someone else's PR cannot.
    public var ownedBranches: [Branch] {
        let shared = Set([defaultBranch ?? "main", "main", "master"])
        if let workBranches {
            return workBranches.filter { !shared.contains($0.name) }.sorted { Self.activity($0.at) > Self.activity($1.at) }
        }
        var found = branches ?? []
        for pr in prs where pr.mine == "created" && (repository == nil || pr.headRepository?.lowercased() == repository?.lowercased()) {
            if let name = pr.headRef, !found.contains(where: { $0.name == name }) {
                found.append(Branch(name: name, pushed: true, at: pr.mineAt))
            }
        }
        return found.filter { !shared.contains($0.name) }.sorted { Self.activity($0.at) > Self.activity($1.at) }
    }

    public func associatedWorktrees(folder: String, branch: String?, dedicated: Bool,
                                    worktrees: [ReviewWorktrees.Worktree], excluding: [String] = []) -> [ReviewWorktrees.Worktree] {
        let names = Set(ownedBranches.map(\.name))
        return worktrees.filter { tree in
            // An assigned path is authoritative even when sibling agents share that tree.
            if dedicated && Self.sameFolder(tree.path, folder) { return true }
            return !excluding.contains(where: { Self.sameFolder(tree.path, $0) }) &&
                ((dedicated && tree.branch == branch && branch != nil) || tree.branch.map(names.contains) == true)
        }.sorted { a, b in
            let ownA = dedicated && Self.sameFolder(a.path, folder)
            let ownB = dedicated && Self.sameFolder(b.path, folder)
            if ownA != ownB { return ownA }
            let atA = max(Self.activity(ownedBranches.first { $0.name == a.branch }?.at), Self.activity(a.activeAt))
            let atB = max(Self.activity(ownedBranches.first { $0.name == b.branch }?.at), Self.activity(b.activeAt))
            return atA == atB ? a.path < b.path : atA > atB
        }
    }

    /// Worktree identity first, then branches actually created/pushed, then an explicit PR
    /// link. Repository activity and PR comments never establish ownership.
    public func target(linkedURL: String?, folder: String, branch: String?, dedicated: Bool,
                       worktrees: [ReviewWorktrees.Worktree], excluding: [String] = []) -> Target? {
        let trees = associatedWorktrees(folder: folder, branch: branch, dedicated: dedicated,
                                        worktrees: worktrees, excluding: excluding)
        if dedicated {
            if let own = trees.first(where: { Self.sameFolder($0.path, folder) }) { return .worktree(own) }
            if let own = trees.first(where: { $0.branch == branch && branch != nil }) { return .worktree(own) }
            // A removed assigned worktree is handled by the kept-branch loader. Don't jump
            // to an older, unrelated PR or worktree in the same repository.
            return nil
        }
        if defaultBranch != nil, let current = worktrees.first(where: { tree in
            Self.sameFolder(tree.path, folder) && tree.branch != nil &&
            ![defaultBranch ?? "main", "main", "master"].contains(tree.branch!) &&
            !excluding.contains(where: { Self.sameFolder(tree.path, $0) })
        }) { return .worktree(current) }
        let candidates = ownedBranches.sorted { a, b in
            let atA = max(Self.activity(a.at), Self.activity(trees.first { $0.branch == a.name }?.activeAt))
            let atB = max(Self.activity(b.at), Self.activity(trees.first { $0.branch == b.name }?.activeAt))
            return atA == atB ? a.name < b.name : atA > atB
        }
        for owned in candidates {
            if let tree = trees.first(where: { $0.branch == owned.name }) { return .worktree(tree) }
            // Do not silently take a branch checked out in another conversation's tree.
            if worktrees.contains(where: { $0.branch == owned.name }) { continue }
            if let pr = pullRequest(for: owned.name) { return .pullRequest(pr.number) }
            if (branches ?? []).contains(where: { $0.name == owned.name }) { return .branch(owned) }
        }
        func belongsElsewhere(_ pr: Item) -> Bool {
            guard let name = pr.headRef,
                  repository == nil || pr.headRepository?.lowercased() == repository?.lowercased() else { return false }
            return worktrees.contains { tree in
                tree.branch == name && excluding.contains { Self.sameFolder(tree.path, $0) }
            }
        }
        if let linkedURL, let number = likely(linkedURL: linkedURL, agentBranches: []) {
            if !prs.contains(where: { $0.number == number && belongsElsewhere($0) }) { return .pullRequest(number) }
        }
        let created = prs.filter { $0.mine == "created" && !belongsElsewhere($0) }
        return created.count == 1 ? .pullRequest(created[0].number) : nil
    }

    public func isConversationWork(_ pr: Item) -> Bool {
        if pr.mine == "created" { return true }
        guard repository == nil || pr.headRepository?.lowercased() == repository?.lowercased(),
              let branch = pr.headRef else { return false }
        return ownedBranches.contains { $0.name == branch }
    }

    public func pullRequest(for branch: String) -> Item? {
        prs.filter { $0.headRef == branch && (repository == nil || $0.headRepository?.lowercased() == repository?.lowercased()) }.sorted {
            if ($0.state == "open") != ($1.state == "open") { return $0.state == "open" }
            return ($0.updatedAt ?? "") > ($1.updatedAt ?? "")
        }.first
    }

    /// The PR to open the window on, by number: the one the runner linked to the conversation
    /// (listed or not), else the only open one whose branch is checked out where the agent
    /// works (`agentBranches`: the folder's branch, worktrees active since it began). Nil when
    /// that's not clear: a PR that merely changed lately may be another conversation's.
    public func likely(linkedURL: String?, agentBranches: Set<String>) -> Int? {
        if let linkedURL {
            if let linked = prs.first(where: { $0.url == linkedURL }) { return linked.number }
            if let number = linkedURL.split(separator: "/").last.flatMap({ Int($0) }) { return number }
        }
        let candidates = prs.filter { $0.state == "open" && $0.headRef.map(agentBranches.contains) == true }
        return candidates.count == 1 ? candidates[0].number : nil
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
