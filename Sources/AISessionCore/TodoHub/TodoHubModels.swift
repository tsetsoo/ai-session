import Foundation

// Mirrors `crates/todo-shared/src/lib.rs` in todo-app. JSON keys are snake_case on the wire;
// `TodoHubClient` converts them with `.convertFromSnakeCase` / `.convertToSnakeCase`.

/// Todo section. The codes are opaque labels — never expand them into names.
public enum TodoSection: String, Codable, CaseIterable, Sendable, Identifiable {
    case sp = "Sp"
    case i = "I"
    case si = "Si"
    case p = "P"

    public var id: String { rawValue }
}

public enum TodoImportance: String, Codable, CaseIterable, Sendable {
    case low, medium, high, critical
}

public enum ConversationStatus: String, Codable, CaseIterable, Sendable {
    case busy, waiting, idle, unknown, closed
}

public struct Todo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var section: TodoSection
    public var title: String
    public var completed: Bool
    public var importance: TodoImportance
    public var dueDate: String?
    public var dailyDate: String?
    public var carriedFrom: String?
    public var createdAt: String
    public var updatedAt: String
    public var completedAt: String?
    /// Absent when the todo has no conversation.
    public var conversationStatus: ConversationStatus?
    /// Absent when the todo has no project (and from servers before projects existed).
    public var projectId: String?

    public init(
        id: String,
        section: TodoSection,
        title: String,
        completed: Bool = false,
        importance: TodoImportance = .medium,
        dueDate: String? = nil,
        dailyDate: String? = nil,
        carriedFrom: String? = nil,
        createdAt: String = "",
        updatedAt: String = "",
        completedAt: String? = nil,
        conversationStatus: ConversationStatus? = nil,
        projectId: String? = nil
    ) {
        self.id = id
        self.section = section
        self.title = title
        self.completed = completed
        self.importance = importance
        self.dueDate = dueDate
        self.dailyDate = dailyDate
        self.carriedFrom = carriedFrom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.conversationStatus = conversationStatus
        self.projectId = projectId
    }
}

public struct Computer: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Tailscale name or IP.
    public var hostname: String
    public var port: Int
    public var username: String
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, name: String, hostname: String, port: Int = 22, username: String,
                createdAt: String = "", updatedAt: String = "") {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SectionComputer: Codable, Equatable, Sendable {
    public var section: TodoSection
    public var computer: Computer
    /// Default working directory for new conversations (may start with `~`).
    public var cwd: String
    public var tool: String
}

public struct Conversation: Codable, Equatable, Sendable {
    public var todoId: String
    public var computer: Computer
    public var cwd: String
    /// `claude`, `codex` (or `cursor` later).
    public var tool: String
    public var tmuxName: String
    /// The tool's own conversation id (`claude --resume <id>`, `codex resume <id>`).
    public var sessionId: String
    public var status: ConversationStatus
    public var statusMessage: String?
    public var statusUpdatedAt: String?
    public var createdAt: String
    /// The project of the conversation's session (absent when none, and from older servers).
    public var projectId: String?

    /// Older servers only send `claude_session_id`.
    @available(*, deprecated, renamed: "sessionId")
    public var claudeSessionId: String { sessionId }

    public init(
        todoId: String,
        computer: Computer,
        cwd: String,
        tool: String,
        tmuxName: String,
        sessionId: String,
        status: ConversationStatus,
        statusMessage: String? = nil,
        statusUpdatedAt: String? = nil,
        createdAt: String = "",
        projectId: String? = nil
    ) {
        self.todoId = todoId
        self.computer = computer
        self.cwd = cwd
        self.tool = tool
        self.tmuxName = tmuxName
        self.sessionId = sessionId
        self.status = status
        self.statusMessage = statusMessage
        self.statusUpdatedAt = statusUpdatedAt
        self.createdAt = createdAt
        self.projectId = projectId
    }

    // Keys are written in camelCase; the hub client's decoder converts snake_case to these.
    private enum CodingKeys: String, CodingKey {
        case todoId, computer, cwd, tool, tmuxName, sessionId, claudeSessionId
        case status, statusMessage, statusUpdatedAt, createdAt, projectId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todoId = try c.decode(String.self, forKey: .todoId)
        computer = try c.decode(Computer.self, forKey: .computer)
        cwd = try c.decode(String.self, forKey: .cwd)
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? "claude"
        tmuxName = try c.decode(String.self, forKey: .tmuxName)
        if let id = try c.decodeIfPresent(String.self, forKey: .sessionId) {
            sessionId = id
        } else {
            sessionId = try c.decode(String.self, forKey: .claudeSessionId)
        }
        status = try c.decode(ConversationStatus.self, forKey: .status)
        statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage)
        statusUpdatedAt = try c.decodeIfPresent(String.self, forKey: .statusUpdatedAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(todoId, forKey: .todoId)
        try c.encode(computer, forKey: .computer)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(tool, forKey: .tool)
        try c.encode(tmuxName, forKey: .tmuxName)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try c.encodeIfPresent(statusUpdatedAt, forKey: .statusUpdatedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(projectId, forKey: .projectId)
    }
}

/// `POST /api/todos/{id}/conversation/link`: attach an existing conversation to a todo.
public struct LinkConversationRequest: Encodable, Sendable {
    public var computerId: String
    public var tool: String
    public var sessionId: String
    public var cwd: String

    public init(computerId: String, tool: String, sessionId: String, cwd: String) {
        self.computerId = computerId
        self.tool = tool
        self.sessionId = sessionId
        self.cwd = cwd
    }
}

/// `POST /api/todos/from-conversation`: create a todo already linked to a conversation.
public struct TodoFromConversationRequest: Encodable, Sendable {
    public var section: TodoSection
    public var title: String
    public var computerId: String
    public var tool: String
    public var sessionId: String
    public var cwd: String

    public init(section: TodoSection, title: String, computerId: String, tool: String, sessionId: String, cwd: String) {
        self.section = section
        self.title = title
        self.computerId = computerId
        self.tool = tool
        self.sessionId = sessionId
        self.cwd = cwd
    }
}

public struct TodoWithConversation: Decodable, Equatable, Sendable {
    public var todo: Todo
    public var conversation: Conversation
}

/// One conversation found on a computer by `ai-todo-sessions list --json`.
/// Shared formatters for `RemoteConversation.updatedDate`, which list rows call while rendering.
/// ISO8601DateFormatter is thread-safe.
private enum RemoteConversationDates {
    static let plain = ISO8601DateFormatter()
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public struct RemoteConversation: Codable, Hashable, Identifiable, Sendable {
    public var tool: String
    public var sessionId: String
    /// `$HOME` already replaced by `~`.
    public var cwd: String
    /// First real user prompt, ≤120 chars.
    public var title: String
    /// ISO 8601 UTC, e.g. `2026-10-16T14:53:02Z`.
    public var updatedAt: String
    public var prompts: Int
    /// A live process is using this conversation right now.
    public var running: Bool
    /// The tmux session whose pane runs it, if any.
    public var tmuxSession: String?

    public var id: String { "\(tool)/\(sessionId)" }

    public init(tool: String, sessionId: String, cwd: String, title: String, updatedAt: String,
                prompts: Int, running: Bool = false, tmuxSession: String? = nil) {
        self.tool = tool
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.prompts = prompts
        self.running = running
        self.tmuxSession = tmuxSession
    }

    public var updatedDate: Date? {
        RemoteConversationDates.plain.date(from: updatedAt) ?? RemoteConversationDates.fractional.date(from: updatedAt)
    }

    /// Decodes the script's JSON array (snake_case keys).
    public static func decodeList(_ data: Data) throws -> [RemoteConversation] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([RemoteConversation].self, from: data)
    }
}

public struct CreateTodoRequest: Encodable, Sendable {
    public var section: TodoSection
    public var title: String
    public var importance: TodoImportance?
    /// The project must exist (`404 Project not found`).
    public var projectId: String?

    public init(section: TodoSection, title: String, importance: TodoImportance? = nil, projectId: String? = nil) {
        self.section = section
        self.title = title
        self.importance = importance
        self.projectId = projectId
    }
}

/// Partial update; `nil` fields are omitted from the request body.
public struct UpdateTodoRequest: Encodable, Sendable {
    public var title: String?
    public var completed: Bool?
    public var section: TodoSection?
    public var importance: TodoImportance?
    /// `nil`: project unchanged (key absent). `.clear` sends `"project_id": null`.
    public var projectId: ProjectChange?

    public init(title: String? = nil, completed: Bool? = nil, section: TodoSection? = nil,
                importance: TodoImportance? = nil, projectId: ProjectChange? = nil) {
        self.title = title
        self.completed = completed
        self.section = section
        self.importance = importance
        self.projectId = projectId
    }

    private enum CodingKeys: String, CodingKey {
        case title, completed, section, importance, projectId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(completed, forKey: .completed)
        try c.encodeIfPresent(section, forKey: .section)
        try c.encodeIfPresent(importance, forKey: .importance)
        try c.encodeChange(projectId, forKey: .projectId)
    }
}

public struct CreateComputerRequest: Encodable, Sendable {
    public var name: String
    public var hostname: String
    public var port: Int?
    public var username: String

    public init(name: String, hostname: String, port: Int? = nil, username: String) {
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
    }
}

public struct SetSectionComputerRequest: Encodable, Sendable {
    public var computerId: String
    public var cwd: String
    public var tool: String?

    public init(computerId: String, cwd: String, tool: String? = nil) {
        self.computerId = computerId
        self.cwd = cwd
        self.tool = tool
    }
}

/// Which todos `GET /api/todos` returns. Default (`nil`) hides todos archived over a day ago.
public enum TodoListFilter: String, Sendable {
    case all
    case archived
}
