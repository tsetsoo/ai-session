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
        case .fixed: "Fixed · deploy, then resolve"
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
