import Foundation

// Projects, sessions (with usage stats), memories and the weekly rollup. Mirrors the todo-app
// schema v3 API. JSON keys are snake_case on the wire; the hub client's decoder/encoder
// converts them, so the coding keys below are written in camelCase.

// MARK: Nullable PATCH fields

/// A PATCH field that can be set or cleared. Wrap it in an `Optional` for the third state,
/// "unchanged", which omits the key from the body.
public enum NullableChange<Value: Encodable & Sendable>: Sendable {
    case set(Value)
    /// Sends an explicit JSON `null`.
    case clear
}

extension NullableChange: Equatable where Value: Equatable {}

/// A todo's (or memory's) project assignment in a PATCH body.
public typealias ProjectChange = NullableChange<String>

extension KeyedEncodingContainer {
    /// `nil` omits the key, `.clear` writes `null`, `.set(v)` writes `v`.
    mutating func encodeChange<Value>(_ change: NullableChange<Value>?, forKey key: Key) throws {
        switch change {
        case nil: break
        case .clear?: try encodeNil(forKey: key)
        case let .set(value)?: try encode(value, forKey: key)
        }
    }
}

// MARK: Dates

/// The hub sends two timestamp spellings: SQLite's `2026-10-16 09:12:03` (UTC, for
/// `created_at` / `updated_at`) and ISO 8601 `2026-10-16T09:12:03Z` (activity times).
public enum HubDates {
    private static let plain = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func date(from string: String?) -> Date? {
        guard var text = string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.count == 19, text.dropFirst(10).first == " " {
            text = text.replacingOccurrences(of: " ", with: "T") + "Z"
        }
        return plain.date(from: text) ?? fractional.date(from: text)
    }
}

// MARK: Projects

/// A folder on a section. Nested folders are their own projects: `~/programming` and
/// `~/programming/sigma-revenue` each keep their own notes.
public struct Project: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var section: TodoSection
    public var computer: Computer
    /// May start with `~`, no trailing `/`.
    public var folder: String
    public var repoUrl: String?
    /// Feed this project's memories into new conversations in its folder.
    public var digestEnabled: Bool
    public var createdAt: String
    public var updatedAt: String
    public var openTodos: Int
    public var sessions: Int
    /// Not archived.
    public var memories: Int
    /// ISO 8601 UTC.
    public var lastActivity: String?

    public init(
        id: String, name: String, computer: Computer, folder: String, section: TodoSection = .si,
        repoUrl: String? = nil,
        digestEnabled: Bool = true, createdAt: String = "", updatedAt: String = "",
        openTodos: Int = 0, sessions: Int = 0, memories: Int = 0, lastActivity: String? = nil
    ) {
        self.id = id
        self.name = name
        self.section = section
        self.computer = computer
        self.folder = folder
        self.repoUrl = repoUrl
        self.digestEnabled = digestEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.openTodos = openTodos
        self.sessions = sessions
        self.memories = memories
        self.lastActivity = lastActivity
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, section, computer, folder, repoUrl, digestEnabled, createdAt, updatedAt
        case openTodos, sessions, memories, lastActivity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        section = try c.decode(TodoSection.self, forKey: .section)
        computer = try c.decode(Computer.self, forKey: .computer)
        folder = try c.decode(String.self, forKey: .folder)
        repoUrl = try c.decodeIfPresent(String.self, forKey: .repoUrl)
        digestEnabled = try c.decodeIfPresent(Bool.self, forKey: .digestEnabled) ?? true
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        openTodos = try c.decodeIfPresent(Int.self, forKey: .openTodos) ?? 0
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        memories = try c.decodeIfPresent(Int.self, forKey: .memories) ?? 0
        lastActivity = try c.decodeIfPresent(String.self, forKey: .lastActivity)
    }

    public var lastActivityDate: Date? { HubDates.date(from: lastActivity) }
}

/// The todo menu's project row. The section code stays the short code (`Sp`, `I`, `Si`, `P`).
public enum TodoProjectMenuTitle {
    public static func row(section: TodoSection, name: String) -> String {
        "\(section.rawValue) · \(name)"
    }
}

/// A folder the hub saw conversations in that could become a project.
/// Accepted through `POST /api/projects` (there is no separate accept endpoint).
public struct ProjectSuggestion: Decodable, Hashable, Identifiable, Sendable {
    public var computer: Computer
    public var folder: String
    public var name: String
    public var repoUrl: String?
    public var sessions: Int
    public var lastActivity: String?
    public var exampleCwds: [String]

    public var id: String { "\(computer.id)|\(folder)" }

    public init(computer: Computer, folder: String, name: String, repoUrl: String? = nil,
                sessions: Int = 0, lastActivity: String? = nil, exampleCwds: [String] = []) {
        self.computer = computer
        self.folder = folder
        self.name = name
        self.repoUrl = repoUrl
        self.sessions = sessions
        self.lastActivity = lastActivity
        self.exampleCwds = exampleCwds
    }

    private enum CodingKeys: String, CodingKey {
        case computer, folder, name, repoUrl, sessions, lastActivity, exampleCwds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        computer = try c.decode(Computer.self, forKey: .computer)
        folder = try c.decode(String.self, forKey: .folder)
        name = try c.decode(String.self, forKey: .name)
        repoUrl = try c.decodeIfPresent(String.self, forKey: .repoUrl)
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        lastActivity = try c.decodeIfPresent(String.self, forKey: .lastActivity)
        exampleCwds = try c.decodeIfPresent([String].self, forKey: .exampleCwds) ?? []
    }

    public var lastActivityDate: Date? { HubDates.date(from: lastActivity) }
}

/// `POST /api/projects`. `nil` fields are omitted.
public struct CreateProjectRequest: Encodable, Sendable {
    public var name: String
    public var section: TodoSection
    public var folder: String
    public var repoUrl: String?
    public var digestEnabled: Bool?

    public init(name: String, section: TodoSection, folder: String, repoUrl: String? = nil, digestEnabled: Bool? = nil) {
        self.name = name
        self.section = section
        self.folder = folder
        self.repoUrl = repoUrl
        self.digestEnabled = digestEnabled
    }
}

/// `PATCH /api/projects/{id}`. `nil` fields are omitted; `repoUrl: .clear` sends `null`.
public struct UpdateProjectRequest: Encodable, Sendable {
    public var name: String?
    public var folder: String?
    public var repoUrl: NullableChange<String>?
    public var digestEnabled: Bool?

    public init(name: String? = nil, folder: String? = nil, repoUrl: NullableChange<String>? = nil, digestEnabled: Bool? = nil) {
        self.name = name
        self.folder = folder
        self.repoUrl = repoUrl
        self.digestEnabled = digestEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case name, folder, repoUrl, digestEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encodeChange(repoUrl, forKey: .repoUrl)
        try c.encodeIfPresent(digestEnabled, forKey: .digestEnabled)
    }
}

// MARK: Sessions

/// Usage numbers of one conversation, computed on its computer without an LLM.
public struct SessionStats: Codable, Hashable, Sendable {
    public var prompts: Int
    public var assistantTurns: Int
    /// `nil` when the transcript has no token figures.
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    public var activeSeconds: Int
    /// ISO 8601 UTC.
    public var firstActivity: String?
    public var lastActivity: String?
    /// Relative to the cwd, at most 200.
    public var filesTouched: [String]
    public var models: [String]

    public init(prompts: Int = 0, assistantTurns: Int = 0, inputTokens: Int? = nil, outputTokens: Int? = nil,
                cacheReadTokens: Int? = nil, cacheCreationTokens: Int? = nil, activeSeconds: Int = 0,
                firstActivity: String? = nil, lastActivity: String? = nil,
                filesTouched: [String] = [], models: [String] = []) {
        self.prompts = prompts
        self.assistantTurns = assistantTurns
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.activeSeconds = activeSeconds
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.filesTouched = filesTouched
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case prompts, assistantTurns, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens
        case activeSeconds, firstActivity, lastActivity, filesTouched, models
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompts = try c.decodeIfPresent(Int.self, forKey: .prompts) ?? 0
        assistantTurns = try c.decodeIfPresent(Int.self, forKey: .assistantTurns) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens)
        activeSeconds = try c.decodeIfPresent(Int.self, forKey: .activeSeconds) ?? 0
        firstActivity = try c.decodeIfPresent(String.self, forKey: .firstActivity)
        lastActivity = try c.decodeIfPresent(String.self, forKey: .lastActivity)
        filesTouched = try c.decodeIfPresent([String].self, forKey: .filesTouched) ?? []
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
    }

    /// Sum of every non-null token figure; `nil` when all are null.
    public var totalTokens: Int? {
        tokenTotal(inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)
    }
}

/// A Claude/Codex conversation known from a computer's transcripts (`GET /api/sessions`),
/// linked to a todo or not. Named `HubSession` to keep it apart from tmux `RemoteSession`s.
public struct HubSession: Decodable, Hashable, Identifiable, Sendable {
    public var tool: String
    public var sessionId: String
    public var computerId: String
    /// With `~`.
    public var cwd: String
    /// First prompt, redacted, ≤ 120 chars.
    public var title: String?
    public var repoRoot: String?
    public var repoUrl: String?
    public var projectId: String?
    /// Set in the app; auto-matching leaves the session alone.
    public var projectOverride: Bool
    public var stats: SessionStats
    public var statsUpdatedAt: String?
    public var createdAt: String
    /// Present when the session is linked to a todo.
    public var todoId: String?
    public var status: ConversationStatus?

    /// Same spelling as `RemoteConversation.id`.
    public var id: String { "\(tool)/\(sessionId)" }

    public init(tool: String, sessionId: String, computerId: String, cwd: String, title: String? = nil,
                repoRoot: String? = nil, repoUrl: String? = nil, projectId: String? = nil,
                projectOverride: Bool = false, stats: SessionStats = SessionStats(),
                statsUpdatedAt: String? = nil, createdAt: String = "",
                todoId: String? = nil, status: ConversationStatus? = nil) {
        self.tool = tool
        self.sessionId = sessionId
        self.computerId = computerId
        self.cwd = cwd
        self.title = title
        self.repoRoot = repoRoot
        self.repoUrl = repoUrl
        self.projectId = projectId
        self.projectOverride = projectOverride
        self.stats = stats
        self.statsUpdatedAt = statsUpdatedAt
        self.createdAt = createdAt
        self.todoId = todoId
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case tool, sessionId, computerId, cwd, title, repoRoot, repoUrl, projectId, projectOverride
        case stats, statsUpdatedAt, createdAt, todoId, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decode(String.self, forKey: .tool)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        computerId = try c.decode(String.self, forKey: .computerId)
        cwd = try c.decode(String.self, forKey: .cwd)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        repoRoot = try c.decodeIfPresent(String.self, forKey: .repoRoot)
        repoUrl = try c.decodeIfPresent(String.self, forKey: .repoUrl)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        // The column is an integer; accept a JSON bool or 0/1.
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .projectOverride) {
            projectOverride = flag
        } else {
            projectOverride = (try c.decodeIfPresent(Int.self, forKey: .projectOverride) ?? 0) != 0
        }
        // The spec lists the session's fields flat; accept them nested under "stats" too.
        if c.contains(.stats) {
            stats = try c.decode(SessionStats.self, forKey: .stats)
        } else {
            stats = try SessionStats(from: decoder)
        }
        statsUpdatedAt = try c.decodeIfPresent(String.self, forKey: .statsUpdatedAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        todoId = try c.decodeIfPresent(String.self, forKey: .todoId)
        status = try c.decodeIfPresent(ConversationStatus.self, forKey: .status)
    }

    public var lastActivityDate: Date? {
        HubDates.date(from: stats.lastActivity) ?? HubDates.date(from: createdAt)
    }
}

/// `PUT /api/sessions/{tool}/{session_id}/project`.
public enum SetSessionProjectRequest: Encodable, Sendable, Equatable {
    /// An override: a project on the session's computer, or `nil` for "no project".
    case project(String?)
    /// Clears the override and re-matches by folder.
    case auto

    private enum CodingKeys: String, CodingKey {
        case projectId, auto
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .project(id?): try c.encode(id, forKey: .projectId)
        case .project(nil): try c.encodeNil(forKey: .projectId)
        case .auto: try c.encode(true, forKey: .auto)
        }
    }
}

// MARK: Weekly stats

private func tokenTotal(_ values: Int?...) -> Int? {
    let present = values.compactMap { $0 }
    return present.isEmpty ? nil : present.reduce(0, +)
}

public struct StatsCounters: Decodable, Hashable, Sendable {
    /// Distinct sessions with at least one day in the week.
    public var sessions: Int
    public var prompts: Int
    public var assistantTurns: Int
    /// `nil` when every summed value was null.
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    public var activeSeconds: Int
    public var filesTouched: Int

    public init(sessions: Int = 0, prompts: Int = 0, assistantTurns: Int = 0, inputTokens: Int? = nil,
                outputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheCreationTokens: Int? = nil,
                activeSeconds: Int = 0, filesTouched: Int = 0) {
        self.sessions = sessions
        self.prompts = prompts
        self.assistantTurns = assistantTurns
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.activeSeconds = activeSeconds
        self.filesTouched = filesTouched
    }

    private enum CodingKeys: String, CodingKey {
        case sessions, prompts, assistantTurns, inputTokens, outputTokens, cacheReadTokens
        case cacheCreationTokens, activeSeconds, filesTouched
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        prompts = try c.decodeIfPresent(Int.self, forKey: .prompts) ?? 0
        assistantTurns = try c.decodeIfPresent(Int.self, forKey: .assistantTurns) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens)
        activeSeconds = try c.decodeIfPresent(Int.self, forKey: .activeSeconds) ?? 0
        filesTouched = try c.decodeIfPresent(Int.self, forKey: .filesTouched) ?? 0
    }

    /// Input + output + cache read + cache creation; `nil` when all are null.
    public var totalTokens: Int? {
        tokenTotal(inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens)
    }
}

/// One `by_project` row; `projectId == nil` collects sessions without a project.
public struct ProjectRollup: Decodable, Hashable, Sendable {
    public var projectId: String?
    public var name: String?
    public var counters: StatsCounters

    private enum CodingKeys: String, CodingKey { case projectId, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        counters = try StatsCounters(from: decoder)
    }
}

/// One `by_section` row; `section == nil` is "unassigned".
public struct SectionRollup: Decodable, Hashable, Sendable {
    public var section: TodoSection?
    public var counters: StatsCounters

    private enum CodingKeys: String, CodingKey { case section }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        section = try c.decodeIfPresent(TodoSection.self, forKey: .section)
        counters = try StatsCounters(from: decoder)
    }
}

public struct ComputerRollup: Decodable, Hashable, Sendable {
    public var computerId: String?
    public var name: String?
    public var counters: StatsCounters

    private enum CodingKeys: String, CodingKey { case computerId, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        computerId = try c.decodeIfPresent(String.self, forKey: .computerId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        counters = try StatsCounters(from: decoder)
    }
}

/// `GET /api/stats/weekly`: Monday-to-Sunday totals and rollups.
public struct WeeklyStats: Decodable, Hashable, Sendable {
    /// `YYYY-MM-DD`, a Monday.
    public var weekStart: String
    public var weekEnd: String
    public var totals: StatsCounters
    public var byProject: [ProjectRollup]
    public var bySection: [SectionRollup]
    public var byComputer: [ComputerRollup]

    public init(weekStart: String, weekEnd: String, totals: StatsCounters,
                byProject: [ProjectRollup] = [], bySection: [SectionRollup] = [], byComputer: [ComputerRollup] = []) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.totals = totals
        self.byProject = byProject
        self.bySection = bySection
        self.byComputer = byComputer
    }

    private enum CodingKeys: String, CodingKey {
        case weekStart, weekEnd, totals, byProject, bySection, byComputer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekStart = try c.decode(String.self, forKey: .weekStart)
        weekEnd = try c.decode(String.self, forKey: .weekEnd)
        totals = try c.decodeIfPresent(StatsCounters.self, forKey: .totals) ?? StatsCounters()
        byProject = try c.decodeIfPresent([ProjectRollup].self, forKey: .byProject) ?? []
        bySection = try c.decodeIfPresent([SectionRollup].self, forKey: .bySection) ?? []
        byComputer = try c.decodeIfPresent([ComputerRollup].self, forKey: .byComputer) ?? []
    }
}

// MARK: Memories

/// The five memory kinds, in the order the app and the digests show them.
public enum MemoryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openThread = "open_thread"
    case decision
    case gotcha
    case done
    case filesChanged = "files_changed"

    public var id: String { rawValue }

    /// Group heading.
    public var title: String {
        switch self {
        case .openThread: "Open threads"
        case .decision: "Decisions"
        case .gotcha: "Gotchas"
        case .done: "Done"
        case .filesChanged: "Files changed"
        }
    }

    /// Singular, for pickers.
    public var label: String {
        switch self {
        case .openThread: "Open thread"
        case .decision: "Decision"
        case .gotcha: "Gotcha"
        case .done: "Done"
        case .filesChanged: "Files changed"
        }
    }

    public var systemImage: String {
        switch self {
        case .openThread: "circle.dashed"
        case .decision: "signpost.right"
        case .gotcha: "exclamationmark.triangle"
        case .done: "checkmark.seal"
        case .filesChanged: "doc.on.doc"
        }
    }
}

/// A short note extracted from a conversation (or added by hand) for a project.
public struct Memory: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var projectId: String?
    public var todoId: String?
    public var computerId: String?
    /// `nil` for manual memories.
    public var tool: String?
    public var sessionId: String?
    public var kind: MemoryKind
    /// One or two sentences, ≤ 400 characters.
    public var text: String
    /// Relative to the project folder.
    public var files: [String]
    public var confidence: Double?
    /// `extracted` or `manual`.
    public var source: String
    public var pinned: Bool
    public var archived: Bool
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, projectId: String? = nil, todoId: String? = nil, computerId: String? = nil,
                tool: String? = nil, sessionId: String? = nil, kind: MemoryKind, text: String,
                files: [String] = [], confidence: Double? = nil, source: String = "extracted",
                pinned: Bool = false, archived: Bool = false, createdAt: String = "", updatedAt: String = "") {
        self.id = id
        self.projectId = projectId
        self.todoId = todoId
        self.computerId = computerId
        self.tool = tool
        self.sessionId = sessionId
        self.kind = kind
        self.text = text
        self.files = files
        self.confidence = confidence
        self.source = source
        self.pinned = pinned
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, todoId, computerId, tool, sessionId, kind, text, files, confidence
        case source, pinned, archived, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        todoId = try c.decodeIfPresent(String.self, forKey: .todoId)
        computerId = try c.decodeIfPresent(String.self, forKey: .computerId)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        kind = try c.decode(MemoryKind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "extracted"
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    public var isManual: Bool { source == "manual" }
    public var createdDate: Date? { HubDates.date(from: createdAt) }
}

/// Filters for `GET /api/memories`. Unset fields are not sent.
public struct MemoryQuery: Equatable, Sendable {
    public var projectId: String?
    public var todoId: String?
    /// Sent comma-separated, e.g. `kind=gotcha,decision`.
    public var kinds: [MemoryKind]
    /// `created_at` ≥ this.
    public var since: String?
    public var tool: String?
    public var sessionId: String?
    public var pinned: Bool?
    public var includeArchived: Bool
    /// Server default 200, max 1000.
    public var limit: Int?

    public init(projectId: String? = nil, todoId: String? = nil, kinds: [MemoryKind] = [], since: String? = nil,
                tool: String? = nil, sessionId: String? = nil, pinned: Bool? = nil,
                includeArchived: Bool = false, limit: Int? = nil) {
        self.projectId = projectId
        self.todoId = todoId
        self.kinds = kinds
        self.since = since
        self.tool = tool
        self.sessionId = sessionId
        self.pinned = pinned
        self.includeArchived = includeArchived
        self.limit = limit
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        func add(_ name: String, _ value: String?) {
            if let value { items.append(URLQueryItem(name: name, value: value)) }
        }
        add("project_id", projectId)
        add("todo_id", todoId)
        if !kinds.isEmpty { add("kind", kinds.map(\.rawValue).joined(separator: ",")) }
        add("since", since)
        add("tool", tool)
        add("session_id", sessionId)
        add("pinned", pinned.map { $0 ? "true" : "false" })
        if includeArchived { add("include_archived", "true") }
        add("limit", limit.map(String.init))
        return items
    }
}

/// `POST /api/memories`: one manual memory. Needs a project or a todo (a todo without a
/// project gives the memory the todo's project).
public struct CreateMemoryRequest: Encodable, Sendable {
    public var kind: MemoryKind
    public var text: String
    public var files: [String]?
    public var projectId: String?
    public var todoId: String?
    public var pinned: Bool?

    public init(kind: MemoryKind, text: String, files: [String]? = nil, projectId: String? = nil,
                todoId: String? = nil, pinned: Bool? = nil) {
        self.kind = kind
        self.text = text
        self.files = files
        self.projectId = projectId
        self.todoId = todoId
        self.pinned = pinned
    }
}

/// `PATCH /api/memories/{id}`. Pin and archive are plain fields here; there are no
/// separate verbs. `nil` fields are omitted, `.clear` sends `null`.
public struct UpdateMemoryRequest: Encodable, Sendable {
    public var text: String?
    public var kind: MemoryKind?
    public var files: [String]?
    public var pinned: Bool?
    public var archived: Bool?
    public var projectId: NullableChange<String>?
    public var todoId: NullableChange<String>?

    public init(text: String? = nil, kind: MemoryKind? = nil, files: [String]? = nil, pinned: Bool? = nil,
                archived: Bool? = nil, projectId: NullableChange<String>? = nil, todoId: NullableChange<String>? = nil) {
        self.text = text
        self.kind = kind
        self.files = files
        self.pinned = pinned
        self.archived = archived
        self.projectId = projectId
        self.todoId = todoId
    }

    private enum CodingKeys: String, CodingKey {
        case text, kind, files, pinned, archived, projectId, todoId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(files, forKey: .files)
        try c.encodeIfPresent(pinned, forKey: .pinned)
        try c.encodeIfPresent(archived, forKey: .archived)
        try c.encodeChange(projectId, forKey: .projectId)
        try c.encodeChange(todoId, forKey: .todoId)
    }
}

// MARK: Repo links

/// Turns a git remote into a page a browser can open.
public enum RepoURL {
    /// `https://…` as is; `git@host:owner/repo.git` and `ssh://git@host/owner/repo.git` become
    /// `https://host/owner/repo`. Anything else is `nil`.
    public static func web(from remote: String?) -> URL? {
        guard var text = remote?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            if text.hasSuffix(".git") { text.removeLast(4) }
            return URL(string: text)
        }
        if text.hasPrefix("ssh://") {
            text.removeFirst("ssh://".count)
            if let at = text.firstIndex(of: "@") { text = String(text[text.index(after: at)...]) }
            // Drop a port: host:22/owner/repo → host/owner/repo.
            if let slash = text.firstIndex(of: "/"), let colon = text[..<slash].firstIndex(of: ":") {
                text = String(text[..<colon]) + String(text[slash...])
            }
        } else if let at = text.firstIndex(of: "@"), let colon = text[at...].firstIndex(of: ":") {
            text = String(text[text.index(after: at)..<colon]) + "/" + String(text[text.index(after: colon)...])
        } else {
            return nil
        }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return URL(string: "https://" + text)
    }
}
