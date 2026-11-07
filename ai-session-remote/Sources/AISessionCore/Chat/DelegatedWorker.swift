import Foundation

/// Work a conversation handed to another agent: a Claude subagent or forked skill, or a Codex
/// spawned agent. One entry of `ai-todo-transcript <tool> <id> --subagents`.
public struct DelegatedWorker: Decodable, Identifiable, Equatable, Sendable {
    /// What the transcripts show. They can't show a pending approval, so there is no "needs you".
    /// `stale`: no finish was recorded and nothing was written for 10 minutes. Unknown, not failed.
    public enum State: String, Decodable, Sendable {
        case working, done, failed, stale

        public init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .stale
        }
    }

    public let id: String
    /// The `--activity` id of the parent's call that started it; nil when the parent's
    /// transcript doesn't have that call (a workflow's or a nested agent's worker).
    public let callId: String?
    public let title: String?
    public let kind: String?
    public let model: String?
    public let background: Bool?
    public let state: State
    /// Why the state is what it is ("handed back its report", "last write 40 s ago").
    public let evidence: String?
    public let startedAt: Date?
    public let lastSeenAt: Date?
    public let durationMs: Int?
    public let tokens: Int?
    public let toolCount: Int?
    public let task: String?
    public let result: String?

    public init(
        id: String, callId: String? = nil, title: String? = nil, kind: String? = nil, model: String? = nil,
        background: Bool? = nil, state: State, evidence: String? = nil, startedAt: Date? = nil,
        lastSeenAt: Date? = nil, durationMs: Int? = nil, tokens: Int? = nil, toolCount: Int? = nil,
        task: String? = nil, result: String? = nil
    ) {
        self.id = id
        self.callId = callId
        self.title = title
        self.kind = kind
        self.model = model
        self.background = background
        self.state = state
        self.evidence = evidence
        self.startedAt = startedAt
        self.lastSeenAt = lastSeenAt
        self.durationMs = durationMs
        self.tokens = tokens
        self.toolCount = toolCount
        self.task = task
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case id, callId, title, kind, model, background, state, evidence, startedAt, lastSeenAt
        case durationMs, tokens, toolCount, task, result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        callId = try container.decodeIfPresent(String.self, forKey: .callId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        background = try container.decodeIfPresent(Bool.self, forKey: .background)
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .stale
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
        startedAt = (try container.decodeIfPresent(String.self, forKey: .startedAt)).flatMap(ConversationMessage.parseTime)
        lastSeenAt = (try container.decodeIfPresent(String.self, forKey: .lastSeenAt)).flatMap(ConversationMessage.parseTime)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        tokens = try container.decodeIfPresent(Int.self, forKey: .tokens)
        toolCount = try container.decodeIfPresent(Int.self, forKey: .toolCount)
        task = try container.decodeIfPresent(String.self, forKey: .task)
        result = try container.decodeIfPresent(String.self, forKey: .result)
    }

    /// The `--subagents` output.
    public static func decodeList(_ data: Data) throws -> [DelegatedWorker] {
        try JSONDecoder().decode([DelegatedWorker].self, from: data)
    }

    /// The card's name: its description, else its agent type, else "Agent".
    public var displayTitle: String {
        for value in [title, kind] {
            if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
        }
        return "Agent"
    }

    /// "4 min · 16 tools · 6k tokens", leaving out what isn't known.
    public var statsLine: String {
        var parts: [String] = []
        if let durationMs { parts.append(Self.duration(durationMs)) }
        if let toolCount { parts.append("\(toolCount) \(toolCount == 1 ? "tool" : "tools")") }
        if let tokens { parts.append(Self.tokenCount(tokens) + " tokens") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ ms: Int) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }

    static func tokenCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}

/// When to ask the computer for a conversation's workers again. The list is only fetched for a
/// chat that delegated, and refreshed while something is still working or a new call appeared.
public enum Delegation {
    /// Tool steps that start a worker: Claude's Agent (Task before it), Codex's spawn_agent.
    public static let startingTools: Set<String> = ["Agent", "Task", "spawn_agent"]

    public static func isStartingCall(_ entry: ConversationMessage) -> Bool {
        entry.role == .activity && startingTools.contains(entry.name ?? entry.target ?? "")
    }

    /// How often to ask again for a call no worker accounts for yet, and while one works.
    /// The chat polls every 1–3 s; listing workers reads the whole parent transcript.
    public static let newCallInterval: TimeInterval = 3
    public static let workingInterval: TimeInterval = 10

    /// True when the chat has a starting call no known worker accounts for, or a worker that
    /// is still working, and the last fetch was long enough ago. Skills forked from a Skill call
    /// show up with the next fetch.
    public static func needsRefresh(
        entries: [ConversationMessage], workers: [DelegatedWorker], lastFetch: Date? = nil, now: Date = Date()
    ) -> Bool {
        let since = lastFetch.map { now.timeIntervalSince($0) } ?? .infinity
        let placed = Set(workers.compactMap(\.callId))
        if since >= newCallInterval, entries.contains(where: { isStartingCall($0) && !placed.contains($0.id) }) { return true }
        return since >= workingInterval && workers.contains { $0.state == .working }
    }
}
