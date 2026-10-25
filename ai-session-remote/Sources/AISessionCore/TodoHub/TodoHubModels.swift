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
    /// MCP servers new conversations on this computer start with. `nil` = not managed, `[]` = none.
    public var mcpDefault: [String]?

    public init(id: String, name: String, hostname: String, port: Int = 22, username: String,
                createdAt: String = "", updatedAt: String = "", mcpDefault: [String]? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mcpDefault = mcpDefault
    }
}

public struct SectionComputer: Codable, Equatable, Sendable {
    public var section: TodoSection
    public var computer: Computer
}

public struct Conversation: Codable, Equatable, Sendable {
    /// Stable id. Empty when decoded from a server that still keys a conversation by todo id.
    public var id: String
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
    /// Name given when this conversation was duplicated. Absent on the original.
    public var label: String?
    /// The MCP servers this conversation was started with. `nil` = not managed (or an older
    /// hub), `[]` = managed with none.
    public var mcpServers: [String]?

    /// Row identity. A conversation from a hub that omits `id` is still the only one on its todo.
    public var listKey: String { id.isEmpty ? todoId : id }

    /// Older servers only send `claude_session_id`.
    @available(*, deprecated, renamed: "sessionId")
    public var claudeSessionId: String { sessionId }

    public init(
        id: String = "",
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
        projectId: String? = nil,
        label: String? = nil,
        mcpServers: [String]? = nil
    ) {
        self.id = id
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
        self.label = label
        self.mcpServers = mcpServers
    }

    // Keys are written in camelCase; the hub client's decoder converts snake_case to these.
    private enum CodingKeys: String, CodingKey {
        case id, todoId, computer, cwd, tool, tmuxName, sessionId, claudeSessionId
        case status, statusMessage, statusUpdatedAt, createdAt, projectId, label, mcpServers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        todoId = try c.decode(String.self, forKey: .todoId)
        computer = try c.decode(Computer.self, forKey: .computer)
        cwd = try c.decode(String.self, forKey: .cwd)
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? "claude"
        tmuxName = try c.decode(String.self, forKey: .tmuxName)
        if let id = try c.decodeIfPresent(String.self, forKey: .sessionId) {
            sessionId = id
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .claudeSessionId) {
            sessionId = legacy
        } else {
            sessionId = ""
        }
        status = try c.decode(ConversationStatus.self, forKey: .status)
        statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage)
        statusUpdatedAt = try c.decodeIfPresent(String.self, forKey: .statusUpdatedAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        mcpServers = try c.decodeIfPresent([String].self, forKey: .mcpServers)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
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
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(mcpServers, forKey: .mcpServers)
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
    public var projectId: String
    public var computerId: String
    public var tool: String
    public var sessionId: String
    public var cwd: String

    public init(
        section: TodoSection, title: String, projectId: String, computerId: String,
        tool: String, sessionId: String, cwd: String
    ) {
        self.section = section
        self.title = title
        self.projectId = projectId
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
    public var title: String
    public var projectId: String
    /// Sent only to reject a section that is not the project's. Omitted uses the project's section.
    public var section: TodoSection?
    public var importance: TodoImportance?

    public init(title: String, projectId: String, section: TodoSection? = nil, importance: TodoImportance? = nil) {
        self.title = title
        self.projectId = projectId
        self.section = section
        self.importance = importance
    }

    private enum CodingKeys: String, CodingKey {
        case title, projectId, section, importance
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(projectId, forKey: .projectId)
        try c.encodeIfPresent(section, forKey: .section)
        try c.encodeIfPresent(importance, forKey: .importance)
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

    public init(computerId: String) {
        self.computerId = computerId
    }
}

public struct OpenConversationRequest: Encodable, Sendable {
    public var tool: String
    /// Omitted when `nil` (not managed).
    public var mcpServers: [String]?

    public init(tool: String, mcpServers: [String]? = nil) {
        self.tool = tool
        self.mcpServers = mcpServers
    }
}

/// `PATCH /api/computers/{id}`. `nil` leaves the default unchanged.
public struct UpdateComputerRequest: Encodable, Sendable {
    public var mcpDefault: MCPDefaultChange?

    public init(mcpDefault: MCPDefaultChange? = nil) {
        self.mcpDefault = mcpDefault
    }

    private enum CodingKeys: String, CodingKey { case mcpDefault }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeMCPDefault(mcpDefault, forKey: .mcpDefault)
    }
}

/// `PUT /api/conversations/{id}/mcp`. The hub requires the key, so `nil` encodes an explicit `null`.
public struct SetConversationServersRequest: Encodable, Sendable {
    public var mcpServers: [String]?

    public init(mcpServers: [String]?) {
        self.mcpServers = mcpServers
    }

    private enum CodingKeys: String, CodingKey { case mcpServers }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let mcpServers { try c.encode(mcpServers, forKey: .mcpServers) } else { try c.encodeNil(forKey: .mcpServers) }
    }
}

public struct DuplicateConversationRequest: Encodable, Sendable {
    public var sourceId: String
    public var tool: String
    public var label: String

    public init(sourceId: String, tool: String, label: String) {
        self.sourceId = sourceId
        self.tool = tool
        self.label = label
    }
}

public struct SetConversationSessionRequest: Encodable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

/// Which todos `GET /api/todos` returns. Default (`nil`) hides todos archived over a day ago.
public enum TodoListFilter: String, Sendable {
    case all
    case archived
}

// MARK: Push notifications

public enum PushPlatform: String, Codable, Sendable {
    case ios, macos
}

/// `PUT /api/push/devices`.
public struct PushDeviceRegistration: Encodable, Sendable {
    /// APNs device token, hex
    public var token: String
    public var platform: PushPlatform
    public var environment: ApsEnvironment
    public var bundleId: String
    public var appVersion: String
    public var deviceName: String?

    public init(token: String, platform: PushPlatform, environment: ApsEnvironment, bundleId: String, appVersion: String, deviceName: String? = nil) {
        self.token = token
        self.platform = platform
        self.environment = environment
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.deviceName = deviceName
    }
}

/// A registered device; the server never returns the full token.
public struct PushDevice: Decodable, Equatable, Sendable {
    public var tokenPrefix: String
    public var platform: PushPlatform
    public var environment: ApsEnvironment
    public var bundleId: String
    public var appVersion: String
    public var deviceName: String?
    public var lastSentAt: String?
    public var lastError: String?
}

public struct QuietHours: Codable, Equatable, Sendable {
    /// `HH:MM`
    public var start: String
    /// `HH:MM`; earlier than `start` means the window crosses midnight
    public var end: String
    /// IANA timezone
    public var tz: String

    public init(start: String, end: String, tz: String) {
        self.start = start
        self.end = end
        self.tz = tz
    }
}

/// `GET`/`PUT /api/push/settings`. The server ignores `mutedTodoIds` on PUT (todo mutes have
/// their own endpoint).
public struct PushSettings: Codable, Equatable, Sendable {
    public var notifyWaiting: Bool
    /// Push when a busy run of at least this many minutes goes idle; `nil` = never
    public var doneAfterMinutes: Int?
    public var graceSeconds: Int
    public var quietHours: QuietHours?
    public var mutedSections: [TodoSection]
    public var mutedTodoIds: [String]

    public init(
        notifyWaiting: Bool = true,
        doneAfterMinutes: Int? = nil,
        graceSeconds: Int = 20,
        quietHours: QuietHours? = nil,
        mutedSections: [TodoSection] = [],
        mutedTodoIds: [String] = []
    ) {
        self.notifyWaiting = notifyWaiting
        self.doneAfterMinutes = doneAfterMinutes
        self.graceSeconds = graceSeconds
        self.quietHours = quietHours
        self.mutedSections = mutedSections
        self.mutedTodoIds = mutedTodoIds
    }
}

/// `GET /api/push/status`.
public struct PushServerStatus: Decodable, Equatable, Sendable {
    public var configured: Bool
    public var lastError: String?
    public var lastSentAt: String?
    public var devices: Int

    public init(configured: Bool, lastError: String?, lastSentAt: String?, devices: Int) {
        self.configured = configured
        self.lastError = lastError
        self.lastSentAt = lastSentAt
        self.devices = devices
    }
}

public struct PushTestResult: Decodable, Equatable, Sendable {
    public var tokenPrefix: String
    public var ok: Bool
    public var reason: String?

    public init(tokenPrefix: String, ok: Bool, reason: String?) {
        self.tokenPrefix = tokenPrefix
        self.ok = ok
        self.reason = reason
    }
}

/// `POST /api/push/presence`. `todo_id` is always sent, `null` to clear.
struct PresenceBody: Encodable {
    var clientId: String
    var todoId: String?

    enum CodingKeys: String, CodingKey { case clientId, todoId }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientId, forKey: .clientId)
        try c.encode(todoId, forKey: .todoId)
    }
}
