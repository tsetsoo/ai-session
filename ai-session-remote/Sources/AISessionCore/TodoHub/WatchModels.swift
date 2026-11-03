import Foundation

// Watchers (`/api/watch/issues`): problems a watcher found (Sentry issues), which debugging
// conversations take and report on, and which the user resolves at the source.

/// A watch job: a check on one computer; with a debug tool, debugging conversations take the
/// open problems.
public struct WatchJobAction: Codable, Equatable, Hashable, Sendable {
    public var projectId: String
    public var computerId: String
    public var watcher: String
    /// `claude` or `codex`; nil: push only.
    public var debugTool: String?
    /// Extra instructions for the debugging conversations.
    public var prompt: String

    public init(projectId: String, computerId: String, watcher: String, debugTool: String?, prompt: String) {
        self.projectId = projectId
        self.computerId = computerId
        self.watcher = watcher
        self.debugTool = debugTool
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey { case projectId, computerId, watcher, debugTool, prompt }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(computerId, forKey: .computerId)
        try c.encode(watcher, forKey: .watcher)
        // The hub reads a missing debug tool as "push only"; send null explicitly.
        try c.encode(debugTool, forKey: .debugTool)
        try c.encode(prompt, forKey: .prompt)
    }
}

/// A watcher problem: `state` open / resolving / cleared; `outcome` fixed / needs_you / cant_fix.
public struct WatchIssue: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var watcher: String
    public var key: String
    public var jobId: String?
    public var projectId: String
    public var title: String
    public var details: String
    public var url: String
    public var folder: String?
    public var state: String
    public var takenRunId: String?
    /// The conversation's todo of the run that took it.
    public var todoId: String?
    public var outcome: String?
    public var outcomeNote: String?
    public var resolveError: String?
    public var firstSeen: String
    public var lastSeen: String
    public var clearedAt: String?
    public var updatedAt: String
    /// The branch of the conversation that took it, where a fix is committed (newer hubs).
    public var branch: String?
    /// That conversation's folder (its worktree).
    public var worktree: String?
    /// The fix's commits, as the agent reported them; [] on an older hub.
    public var commits: [String]

    private enum CodingKeys: String, CodingKey {
        case id, watcher, key, jobId, projectId, title, details, url, folder, state, takenRunId, todoId, outcome, outcomeNote
        case resolveError, firstSeen, lastSeen, clearedAt, updatedAt, branch, worktree, commits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        watcher = try c.decode(String.self, forKey: .watcher)
        key = try c.decode(String.self, forKey: .key)
        jobId = try c.decodeIfPresent(String.self, forKey: .jobId)
        projectId = try c.decode(String.self, forKey: .projectId)
        title = try c.decode(String.self, forKey: .title)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        state = try c.decode(String.self, forKey: .state)
        takenRunId = try c.decodeIfPresent(String.self, forKey: .takenRunId)
        todoId = try c.decodeIfPresent(String.self, forKey: .todoId)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        outcomeNote = try c.decodeIfPresent(String.self, forKey: .outcomeNote)
        resolveError = try c.decodeIfPresent(String.self, forKey: .resolveError)
        firstSeen = try c.decode(String.self, forKey: .firstSeen)
        lastSeen = try c.decode(String.self, forKey: .lastSeen)
        clearedAt = try c.decodeIfPresent(String.self, forKey: .clearedAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
        commits = try c.decodeIfPresent([String].self, forKey: .commits) ?? []
    }

    /// What became of it, in words.
    public var outcomeText: String {
        if state == "cleared" { return "Cleared" }
        switch group {
        case .waiting: return "Waiting for a conversation"
        case .working: return "Being worked on"
        case .needsYou: return "Needs your decision"
        case .cantFix: return "Can't be fixed in code"
        case .fixed: return "Fixed by the conversation"
        case .resolving: return "Resolving…"
        }
    }

    /// What the user does next, in order. `resolveLabel`: the watcher's button ("Resolve in Sentry").
    public func nextSteps(resolveLabel: String) -> [String] {
        if state == "cleared" { return [] }
        switch group {
        case .fixed:
            return ["Review the fix in the conversation.",
                    "Merge the branch and deploy it yourself. Nothing was merged, pushed or deployed.",
                    "Then press \(resolveLabel)."]
        case .needsYou:
            return ["Answer the question in the conversation.", "Then press Try Again, or \(resolveLabel) if it's settled."]
        case .cantFix:
            return ["Read why in the note.", "If it was a one-off, press \(resolveLabel); otherwise Try Again."]
        case .waiting:
            return ["A conversation takes it on the next check (at most 2 work at once)."]
        case .working:
            return ["Watch the conversation; it reports back here."]
        case .resolving:
            return ["This Mac resolves it within a minute."]
        }
    }

    public var group: WatchIssueGroup {
        if state == "resolving" { return .resolving }
        switch outcome {
        case "fixed": return .fixed
        case "needs_you": return .needsYou
        case "cant_fix": return .cantFix
        default: return takenRunId == nil ? .waiting : .working
        }
    }

    /// Needs-you and can't-fix issues can be handed to a new conversation.
    public var canRetry: Bool { group == .needsYou || group == .cantFix }
}

public enum WatchIssueGroup: String, CaseIterable, Hashable, Sendable {
    case waiting, working, needsYou, cantFix, fixed, resolving

    public var title: String {
        switch self {
        case .waiting: "Waiting"
        case .working: "Being worked on"
        case .needsYou: "Needs you"
        case .cantFix: "Can't fix"
        case .fixed: "Fixed on a branch · waiting for your merge"
        case .resolving: "Resolving"
        }
    }
}

public enum WatchIssueGrouping {
    /// Issues by group, in `WatchIssueGroup.allCases` order; empty groups left out.
    public static func grouped(_ issues: [WatchIssue]) -> [(group: WatchIssueGroup, issues: [WatchIssue])] {
        WatchIssueGroup.allCases.compactMap { group in
            let members = issues.filter { $0.group == group }
            return members.isEmpty ? nil : (group, members)
        }
    }
}

/// A watcher installed on a computer (its manifest); settings say only whether they are set.
public struct WatcherInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var settings: [WatcherSetting]
    public var resolve: Bool
    public var resolveLabel: String?
    public var id: String { name }

    /// Required settings not in the env file (optional ones have defaults).
    public var missingSettings: [WatcherSetting] { settings.filter { !$0.set && !$0.optional } }
}

public struct WatcherSetting: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var label: String
    public var secret: Bool
    public var set: Bool
    /// The watcher works without it; false on an older hub.
    public var optional: Bool

    private enum CodingKeys: String, CodingKey { case key, label, secret, set, optional }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
        set = try c.decodeIfPresent(Bool.self, forKey: .set) ?? false
        optional = try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false
    }
}
