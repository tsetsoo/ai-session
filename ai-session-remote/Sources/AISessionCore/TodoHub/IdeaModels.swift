import Foundation

// Ideas per project (`/api/ideas`): added in the app, by an agent (`ai-todo-idea`), or proposed
// by an agent for approval. A research job picks the next one and stores its findings.

public enum IdeaStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case new, researching, researched, dropped

    public var label: String {
        switch self {
        case .new: "New"
        case .researching: "Researching"
        case .researched: "Researched"
        case .dropped: "Dropped"
        }
    }
}

public struct Idea: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var projectId: String
    public var title: String
    public var notes: String
    public var status: IdeaStatus
    public var starred: Bool
    /// Proposed by an agent; waits for the user's OK.
    public var pending: Bool
    public var findings: String?
    /// The research todo, or the todo it was turned into.
    public var todoId: String?
    public var runId: String?
    /// `manual` or `agent`.
    public var source: String
    public var createdAt: String
    public var updatedAt: String
}

public struct CreateIdeaRequest: Encodable, Sendable {
    public var projectId: String
    public var title: String
    public var notes: String?

    public init(projectId: String, title: String, notes: String? = nil) {
        self.projectId = projectId
        self.title = title
        self.notes = notes
    }
}

/// `PATCH /api/ideas/{id}`; nil fields are left as they are. `pending: false` approves.
public struct UpdateIdeaRequest: Encodable, Sendable {
    public var title: String?
    public var notes: String?
    public var status: IdeaStatus?
    public var starred: Bool?
    public var pending: Bool?

    public init(title: String? = nil, notes: String? = nil, status: IdeaStatus? = nil, starred: Bool? = nil,
                pending: Bool? = nil) {
        self.title = title
        self.notes = notes
        self.status = status
        self.starred = starred
        self.pending = pending
    }
}

struct ShapeIdeaRequest: Encodable, Sendable {
    var projectId: String
    var hint: String
}

struct IdeaTodoResponse: Decodable, Sendable {
    var idea: Idea
    var todoId: String
}
