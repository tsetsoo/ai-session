import Foundation

// `GET /api/todos/{id}/usage` and `GET /api/jobs/{id}/usage`: what a todo's or job's
// conversations used themselves (`own`) and what their sub-agents used (`workers`).
// Counts only. Subscription quota is never shown as money per conversation.

/// Output + cache-creation tokens: what eats the limits. Cache reads are cheap and make up
/// most of the input, so raw totals would rank the wrong thing.
public func limitWeight(output: Int?, cacheCreation: Int?) -> Int {
    (output ?? 0) + (cacheCreation ?? 0)
}

extension StatsCounters {
    /// Output + cache-creation tokens (see `limitWeight`).
    public var weight: Int { limitWeight(output: outputTokens, cacheCreation: cacheCreationTokens) }

    /// Field-by-field sum; token fields stay `nil` only when both are.
    public static func + (a: StatsCounters, b: StatsCounters) -> StatsCounters {
        func add(_ x: Int?, _ y: Int?) -> Int? { x == nil && y == nil ? nil : (x ?? 0) + (y ?? 0) }
        return StatsCounters(
            sessions: a.sessions + b.sessions, prompts: a.prompts + b.prompts,
            assistantTurns: a.assistantTurns + b.assistantTurns,
            inputTokens: add(a.inputTokens, b.inputTokens), outputTokens: add(a.outputTokens, b.outputTokens),
            cacheReadTokens: add(a.cacheReadTokens, b.cacheReadTokens),
            cacheCreationTokens: add(a.cacheCreationTokens, b.cacheCreationTokens),
            activeSeconds: a.activeSeconds + b.activeSeconds, filesTouched: a.filesTouched + b.filesTouched)
    }
}

/// Tokens of one model over the conversations, own and workers together.
public struct ModelUsage: Decodable, Hashable, Sendable, Identifiable {
    public var model: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?

    public var id: String { model }
    public var weight: Int { limitWeight(output: outputTokens, cacheCreation: cacheCreationTokens) }

    /// `claude-opus-5-5` → `opus-5-5`; other names stay as they are.
    public var shortName: String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }
}

/// Workers of one kind and type, e.g. seven `Explore` sub-agents.
public struct WorkerTypeUsage: Decodable, Hashable, Sendable, Identifiable {
    /// `agent` or `internal`
    public var kind: String
    public var type: String?
    public var counters: StatsCounters

    public var id: String { "\(kind)|\(type ?? "")" }
    public var title: String { type ?? (kind == "internal" ? "internal" : "sub-agent") }

    private enum CodingKeys: String, CodingKey { case kind, type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "agent"
        type = try c.decodeIfPresent(String.self, forKey: .type)
        counters = try StatsCounters(from: decoder)
    }
}

/// Why a conversation has numbers or not.
public enum UsageReading: String, Decodable, Hashable, Sendable {
    case uploaded
    case cursor
    case noSession = "no_session"
    case notUploaded = "not_uploaded"
    case unknown

    public init(from decoder: Decoder) throws {
        self = UsageReading(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    /// Why there are no numbers; `nil` when there are.
    public var missingReason: String? {
        switch self {
        case .uploaded: nil
        case .cursor: "Cursor keeps no token counts"
        case .noSession: "No session id yet"
        case .notUploaded: "Not uploaded yet"
        case .unknown: "No reading"
        }
    }
}

public struct ConversationUsage: Decodable, Hashable, Sendable, Identifiable {
    public var conversationId: String
    public var todoId: String
    public var tool: String
    public var sessionId: String?
    public var computerId: String
    public var label: String?
    public var title: String?
    public var reading: UsageReading
    public var own: StatsCounters
    public var workers: StatsCounters
    public var firstActivity: String?
    public var lastActivity: String?
    public var statsUpdatedAt: String?

    public var id: String { conversationId }
}

/// Usage summed over a set of conversations. `own + workers` is everything they used.
public struct UsageSummary: Decodable, Hashable, Sendable {
    public var own: StatsCounters
    public var workers: StatsCounters
    /// Heaviest first
    public var byModel: [ModelUsage]
    /// Heaviest first
    public var workerTypes: [WorkerTypeUsage]
    public var firstActivity: String?
    public var lastActivity: String?
    /// First to last activity, workers included
    public var elapsedSeconds: Int?
    /// The oldest upload among the conversations with numbers
    public var statsUpdatedAt: String?
    public var unreadConversations: Int
    public var conversations: [ConversationUsage]

    public var total: StatsCounters { own + workers }
    /// Nothing uploaded for any conversation.
    public var isEmpty: Bool { own.sessions == 0 && workers.sessions == 0 }

    public init(own: StatsCounters = StatsCounters(), workers: StatsCounters = StatsCounters(),
                byModel: [ModelUsage] = [], workerTypes: [WorkerTypeUsage] = [], firstActivity: String? = nil,
                lastActivity: String? = nil, elapsedSeconds: Int? = nil, statsUpdatedAt: String? = nil,
                unreadConversations: Int = 0, conversations: [ConversationUsage] = []) {
        self.own = own
        self.workers = workers
        self.byModel = byModel
        self.workerTypes = workerTypes
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.elapsedSeconds = elapsedSeconds
        self.statsUpdatedAt = statsUpdatedAt
        self.unreadConversations = unreadConversations
        self.conversations = conversations
    }

    private enum CodingKeys: String, CodingKey {
        case own, workers, byModel, workerTypes, firstActivity, lastActivity, elapsedSeconds, statsUpdatedAt
        case unreadConversations, conversations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        own = try c.decodeIfPresent(StatsCounters.self, forKey: .own) ?? StatsCounters()
        workers = try c.decodeIfPresent(StatsCounters.self, forKey: .workers) ?? StatsCounters()
        byModel = try c.decodeIfPresent([ModelUsage].self, forKey: .byModel) ?? []
        workerTypes = try c.decodeIfPresent([WorkerTypeUsage].self, forKey: .workerTypes) ?? []
        firstActivity = try c.decodeIfPresent(String.self, forKey: .firstActivity)
        lastActivity = try c.decodeIfPresent(String.self, forKey: .lastActivity)
        elapsedSeconds = try c.decodeIfPresent(Int.self, forKey: .elapsedSeconds)
        statsUpdatedAt = try c.decodeIfPresent(String.self, forKey: .statsUpdatedAt)
        unreadConversations = try c.decodeIfPresent(Int.self, forKey: .unreadConversations) ?? 0
        conversations = try c.decodeIfPresent([ConversationUsage].self, forKey: .conversations) ?? []
    }
}

/// `GET /api/todos/{id}/usage`
public struct TodoUsage: Decodable, Hashable, Sendable {
    public var todoId: String
    public var usage: UsageSummary

    private enum CodingKeys: String, CodingKey { case todoId }

    public init(todoId: String, usage: UsageSummary) {
        self.todoId = todoId
        self.usage = usage
    }

    public init(from decoder: Decoder) throws {
        todoId = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .todoId)
        usage = try UsageSummary(from: decoder)
    }
}

/// One run of a job with its todo's usage.
public struct RunUsage: Decodable, Hashable, Sendable, Identifiable {
    public var runId: String
    public var dueAt: String
    public var state: String
    public var todoId: String?
    public var usage: UsageSummary

    public var id: String { runId }

    private enum CodingKeys: String, CodingKey { case runId, dueAt, state, todoId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(String.self, forKey: .runId)
        dueAt = try c.decode(String.self, forKey: .dueAt)
        state = try c.decode(String.self, forKey: .state)
        todoId = try c.decodeIfPresent(String.self, forKey: .todoId)
        usage = try UsageSummary(from: decoder)
    }
}

/// `GET /api/jobs/{id}/usage`: all runs summed, then the newest runs one by one.
public struct JobUsage: Decodable, Hashable, Sendable {
    public var jobId: String
    public var usage: UsageSummary
    public var runs: [RunUsage]

    private enum CodingKeys: String, CodingKey { case jobId, runs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(String.self, forKey: .jobId)
        runs = try c.decodeIfPresent([RunUsage].self, forKey: .runs) ?? []
        usage = try UsageSummary(from: decoder)
    }
}
