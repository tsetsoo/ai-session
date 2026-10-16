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
        conversationStatus: ConversationStatus? = nil
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
    }
}

public struct Computer: Codable, Equatable, Identifiable, Sendable {
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
    public var tool: String
    public var tmuxName: String
    public var claudeSessionId: String
    public var status: ConversationStatus
    public var statusMessage: String?
    public var statusUpdatedAt: String?
    public var createdAt: String
}

public struct CreateTodoRequest: Encodable, Sendable {
    public var section: TodoSection
    public var title: String
    public var importance: TodoImportance?

    public init(section: TodoSection, title: String, importance: TodoImportance? = nil) {
        self.section = section
        self.title = title
        self.importance = importance
    }
}

/// Partial update; `nil` fields are omitted from the request body.
public struct UpdateTodoRequest: Encodable, Sendable {
    public var title: String?
    public var completed: Bool?
    public var section: TodoSection?
    public var importance: TodoImportance?

    public init(title: String? = nil, completed: Bool? = nil, section: TodoSection? = nil,
                importance: TodoImportance? = nil) {
        self.title = title
        self.completed = completed
        self.section = section
        self.importance = importance
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
