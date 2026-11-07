import Foundation

/// Work a conversation handed to another agent: a Claude subagent or forked skill, or a Codex
/// spawned agent. One entry of `ai-todo-transcript <tool> <id> --subagents`.
public struct DelegatedWorker: Decodable, Identifiable, Equatable, Sendable {
    /// What the transcripts show. They can't show a pending approval: "needs you" comes from the
    /// hub's status (`needsYou`, see `merging(hub:)`). `stale`: no finish was recorded and nothing was written for 10 minutes. Unknown, not failed.
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
    public var state: State
    /// The worker waits on an approval or a question, as the computer's status hooks saw it.
    public var needsYou: Bool = false
    /// What it waits on ("Claude needs approval"), with `needsYou`.
    public var needsYouMessage: String?
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

    /// The transcripts' workers corrected by the hub's status: a worker the hooks saw waiting
    /// needs you, and one they still see running is working even when its transcript went quiet
    /// (one long tool call). The transcript's done or failed wins: it is written last.
    public static func merging(_ workers: [DelegatedWorker], hub: [WorkerStatus]?) -> [DelegatedWorker] {
        guard let hub, !hub.isEmpty else { return workers }
        let byId = Dictionary(hub.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return workers.map { worker in
            guard let status = byId[worker.id], worker.state == .working || worker.state == .stale else { return worker }
            var merged = worker
            if status.isWorking { merged.state = .working }
            if status.needsYou && status.isWorking {
                merged.needsYou = true
                merged.needsYouMessage = status.message
            }
            return merged
        }
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

    /// The card's line under the title, in plain words; nil for a done worker with a result.
    /// `evidence` stays for the sheet's details.
    public func statusText(now: Date = Date()) -> String? {
        let ago = lastSeenAt.map { Self.elapsed(now.timeIntervalSince($0)) }
        if needsYou { return needsYouMessage ?? "Waiting for your approval or answer" }
        switch state {
        case .working:
            return ago.map { "Last update \($0) ago" } // the state label already says Working
        case .stale:
            return ago.map { "No update for \($0). It may still be running." } ?? "No update recorded."
        case .failed:
            guard let reason = evidence?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return "Failed" }
            return reason.prefix(1).uppercased() + reason.dropFirst()
        case .done:
            return result == nil ? "Finished" : nil
        }
    }

    /// "just now", "40 s", "12 min", "3 h", "2 days".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h" }
        let days = s / 86400
        return "\(days) \(days == 1 ? "day" : "days")"
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
    /// A running worker the hub reports that the list doesn't have yet is asked about at the
    /// working pace: a nested agent's worker may never appear in this conversation's list.
    public static func needsRefresh(
        entries: [ConversationMessage], workers: [DelegatedWorker], lastFetch: Date? = nil, now: Date = Date(),
        hub: [WorkerStatus]? = nil
    ) -> Bool {
        let since = lastFetch.map { now.timeIntervalSince($0) } ?? .infinity
        let placed = Set(workers.compactMap(\.callId))
        if since >= newCallInterval, entries.contains(where: { isStartingCall($0) && !placed.contains($0.id) }) { return true }
        let known = Set(workers.map(\.id))
        if since >= workingInterval, (hub ?? []).contains(where: { $0.isWorking && !known.contains($0.id) }) { return true }
        return since >= workingInterval && workers.contains { $0.state == .working }
    }
}

/// Counts for the strip over a chat ("2 working · 1 needs you · 1 done") and the Mac's mark.
public struct WorkerTally: Equatable, Sendable {
    public var working = 0
    public var needsYou = 0
    public var done = 0
    public var failed = 0

    public init(working: Int = 0, needsYou: Int = 0, done: Int = 0, failed: Int = 0) {
        self.working = working
        self.needsYou = needsYou
        self.done = done
        self.failed = failed
    }

    /// From the hub alone: what the Mac's toolbar and list use, with no check on the computer.
    public init(hub: [WorkerStatus]?) {
        for status in hub ?? [] {
            if status.needsYou && status.isWorking { needsYou += 1 } else if status.isWorking { working += 1 } else { done += 1 }
        }
    }

    /// From the chat's merged workers. A stale worker counts as working: it may still run.
    public init(workers: [DelegatedWorker]) {
        for worker in workers {
            if worker.needsYou { needsYou += 1; continue }
            switch worker.state {
            case .working, .stale: working += 1
            case .done: done += 1
            case .failed: failed += 1
            }
        }
    }

    public var total: Int { working + needsYou + done + failed }
    public var active: Int { working + needsYou }

    /// The strip shows only with more than one worker: one card already says it all.
    public var showsStrip: Bool { total > 1 }

    /// "2 working · 1 needs you · 1 done", leaving out zeros.
    public var summary: String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if needsYou > 0 { parts.append("\(needsYou) needs you") }
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}
