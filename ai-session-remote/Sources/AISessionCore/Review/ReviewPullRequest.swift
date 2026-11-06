import CryptoKit
import Foundation

/// `ai-todo-review pr`: the branch's pull/merge request, as far as the computer's gh or glab
/// can tell. Read-only.
public struct ReviewPullRequestInfo: Codable, Equatable, Sendable {
    public struct Checks: Codable, Equatable, Sendable {
        /// `passing`, `failing`, `pending` or `none`.
        public var state: String
        public var passed: Int
        public var failed: Int
        public var pending: Int
        public var total: Int

        public init(state: String, passed: Int = 0, failed: Int = 0, pending: Int = 0, total: Int = 0) {
            self.state = state
            self.passed = passed
            self.failed = failed
            self.pending = pending
            self.total = total
        }
    }

    public struct PullRequest: Codable, Equatable, Sendable {
        public var number: Int
        public var url: String?
        public var title: String
        public var body: String
        /// `open`, `merged` or `closed`.
        public var state: String
        public var draft: Bool
        public var author: String?
        /// GitHub's `approved` / `changes_requested` / `review_required`; GitLab: `approved` or nil.
        public var reviewDecision: String?
        public var approvals: [String]
        /// The forge's own word: `clean`, `blocked`, `mergeable`, `ci_still_running`, …
        public var mergeable: String?
        public var checks: Checks
        public var headSHA: String?
        public var headRef: String?
        public var baseRef: String?
        /// GitLab's project id, for asking about the MR again.
        public var projectID: Int?

        private enum CodingKeys: String, CodingKey {
            case number, url, title, body, state, draft, author, approvals, mergeable, checks
            case reviewDecision = "review_decision", headSHA = "head_sha", headRef = "head_ref", baseRef = "base_ref"
            case projectID = "project_id"
        }

        public init(number: Int, url: String?, title: String, body: String, state: String, draft: Bool, author: String?,
                    reviewDecision: String? = nil, approvals: [String] = [], mergeable: String? = nil,
                    checks: Checks = Checks(state: "none"), headSHA: String? = nil, headRef: String? = nil, baseRef: String? = nil) {
            self.number = number
            self.url = url
            self.title = title
            self.body = body
            self.state = state
            self.draft = draft
            self.author = author
            self.reviewDecision = reviewDecision
            self.approvals = approvals
            self.mergeable = mergeable
            self.checks = checks
            self.headSHA = headSHA
            self.headRef = headRef
            self.baseRef = baseRef
        }

        /// `PR #9` on GitHub, `MR !4` on GitLab.
        public func name(provider: String?) -> String {
            provider == "gitlab" ? "MR !\(number)" : "PR #\(number)"
        }
    }

    /// `github`, `gitlab`, or nil when origin is neither.
    public var provider: String?
    /// gh/glab could be asked. False with `error` when it is missing, logged out or failing.
    public var access: Bool
    public var error: String?
    /// Who gh/glab act as on that computer.
    public var viewer: String?
    public var branch: String?
    public var pr: PullRequest?

    public init(provider: String?, access: Bool, error: String? = nil, viewer: String? = nil, branch: String? = nil,
                pr: PullRequest? = nil) {
        self.provider = provider
        self.access = access
        self.error = error
        self.viewer = viewer
        self.branch = branch
        self.pr = pr
    }
}

/// `ai-todo-review threads`: review threads on lines of the PR/MR.
public struct ReviewThreadsResult: Codable, Equatable, Sendable {
    public struct Thread: Codable, Equatable, Sendable {
        public struct Comment: Codable, Equatable, Sendable {
            public var author: String
            public var body: String
            public var createdAt: String?

            private enum CodingKeys: String, CodingKey {
                case author, body
                case createdAt = "created_at"
            }

            public init(author: String, body: String, createdAt: String? = nil) {
                self.author = author
                self.body = body
                self.createdAt = createdAt
            }
        }

        public var id: String
        public var path: String
        public var side: DiffSide
        public var lineStart: Int?
        public var lineEnd: Int?
        /// The commit its lines are in.
        public var commit: String?
        public var resolved: Bool
        public var outdated: Bool
        public var url: String?
        public var comments: [Comment]

        private enum CodingKeys: String, CodingKey {
            case id, path, side, commit, resolved, outdated, url, comments
            case lineStart = "line_start", lineEnd = "line_end"
        }

        public init(id: String, path: String, side: DiffSide = .new, lineStart: Int?, lineEnd: Int?, commit: String?,
                    resolved: Bool = false, outdated: Bool = false, url: String? = nil, comments: [Comment]) {
            self.id = id
            self.path = path
            self.side = side
            self.lineStart = lineStart
            self.lineEnd = lineEnd
            self.commit = commit
            self.resolved = resolved
            self.outdated = outdated
            self.url = url
            self.comments = comments
        }
    }

    public var provider: String?
    public var access: Bool
    public var error: String?
    /// The PR/MR number, or nil when the branch has none.
    public var pr: Int?
    public var threads: [Thread]

    public init(provider: String?, access: Bool, error: String? = nil, pr: Int?, threads: [Thread]) {
        self.provider = provider
        self.access = access
        self.error = error
        self.pr = pr
        self.threads = threads
    }
}

/// PR/MR review threads as review items: one per unresolved thread on lines, its author the
/// one who started it, so it can go to the agent like any other comment.
public enum ReviewThreadItems {
    public static let authorPrefix = "pr:"

    public static func fingerprint(_ thread: ReviewThreadsResult.Thread) -> String { "thread:\(thread.id)" }

    /// The same id for the same thread of the same conversation on every device, so two
    /// devices adding it write one row on the hub, not two.
    public static func itemID(conversationKey: String, thread: ReviewThreadsResult.Thread) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("review-thread\u{0}\(conversationKey)\u{0}\(thread.id)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The thread's conversation as one body: `bob: Rename this` / `alice: Why?`.
    public static func body(_ thread: ReviewThreadsResult.Thread) -> String {
        let text = thread.comments.map { "\($0.author): \($0.body.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
        // As the hub keeps it, so it compares equal after a round trip.
        return String(text.prefix(ReviewSync.maxBody))
    }

    /// What changes in `existing` for these threads: new unresolved threads to add, open
    /// items whose thread got replies (their body follows), and open items whose thread was
    /// resolved (dismissed). Items the user sent, picked or dismissed stay as they are.
    /// Replies follow only while the body is still the thread's own text (the user hasn't
    /// edited it): the new text then starts with the old.
    public static func apply(_ result: ReviewThreadsResult, provider: String?, fallbackRevision: String,
                             conversationKey: String, to comments: inout [ReviewComment], at date: Date = .now) -> Int {
        var changed = 0
        let label = provider == "gitlab" ? "GitLab" : "GitHub"
        for thread in result.threads where !thread.comments.isEmpty {
            let print = fingerprint(thread)
            if let index = comments.firstIndex(where: { $0.fingerprint == print }) {
                guard comments[index].state == .new else { continue }
                if thread.resolved {
                    comments[index].state = .dismissed
                    changed += 1
                } else if comments[index].body != body(thread), body(thread).hasPrefix(comments[index].body) {
                    comments[index].body = body(thread)
                    changed += 1
                }
                continue
            }
            guard !thread.resolved else { continue }
            let start = thread.lineStart ?? thread.lineEnd
            comments.append(ReviewComment(
                id: itemID(conversationKey: conversationKey, thread: thread),
                author: authorPrefix + thread.comments[0].author, path: thread.path, side: thread.side,
                startLine: start, endLine: thread.lineEnd.flatMap { $0 == start ? nil : $0 },
                revision: thread.commit ?? fallbackRevision, quote: [], body: body(thread), state: .new,
                createdAt: date, category: "pr", title: "\(label) thread by \(thread.comments[0].author)",
                fingerprint: print
            ))
            changed += 1
        }
        return changed
    }
}

extension ReviewComment {
    /// Not the user's own: a reviewer agent's finding or a PR/MR thread. They arrive as `new`
    /// and join a batch only when the user picks them.
    public var isFinding: Bool { reviewer != nil || prAuthor != nil }

    /// `pr:bob` → `bob`.
    public var prAuthor: String? {
        author.hasPrefix(ReviewThreadItems.authorPrefix) ? String(author.dropFirst(ReviewThreadItems.authorPrefix.count)) : nil
    }
}

extension TmuxCommandBuilder {
    private static let prHelper = "\"$HOME/.ai-remote/bin/ai-todo-review\""

    public static func reviewPullRequest(cwd: String, ref: String? = nil) -> String {
        wrap("exec \(prHelper) pr \(shellQuotePath(cwd))" + (ref.map { " --ref \(shellQuote($0))" } ?? ""))
    }

    /// With `number` and the PR's `url` (GitHub) or `projectID` (GitLab) from `pr`, the
    /// helper doesn't look the PR up again.
    public static func reviewThreads(cwd: String, ref: String? = nil, number: Int? = nil, url: String? = nil,
                                     projectID: Int? = nil) -> String {
        var command = "exec \(prHelper) threads \(shellQuotePath(cwd))"
        if let ref { command += " --ref \(shellQuote(ref))" }
        if let number { command += " --number \(number)" }
        if let url { command += " --url \(shellQuote(url))" }
        if let projectID { command += " --project \(projectID)" }
        return wrap(command)
    }
}
