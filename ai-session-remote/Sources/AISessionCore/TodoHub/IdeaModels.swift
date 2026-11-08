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

/// What saving the idea editor sends: only the fields the user changed, so a status a research
/// run set meanwhile isn't overwritten with the editor's stale copy. Nil when nothing changed.
public enum IdeaEdit {
    public static func request(original: Idea, title: String, notes: String, status: IdeaStatus,
                               starred: Bool) -> UpdateIdeaRequest? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = UpdateIdeaRequest()
        if title != original.title { request.title = title }
        if notes != original.notes { request.notes = notes }
        if status != original.status { request.status = status }
        if starred != original.starred { request.starred = starred }
        let changed = request.title != nil || request.notes != nil || request.status != nil || request.starred != nil
        return changed ? request : nil
    }
}

/// The filter chips of the Ideas list. "All" leaves out dropped ideas and ones waiting for OK.
public enum IdeaFilter: String, CaseIterable, Hashable, Sendable {
    case all, new, researching, researched, waiting, dropped

    public var label: String {
        switch self {
        case .all: "All"
        case .new: "New"
        case .researching: "Researching"
        case .researched: "Researched"
        case .waiting: "Waiting for OK"
        case .dropped: "Dropped"
        }
    }

    public func matches(_ idea: Idea) -> Bool {
        switch self {
        case .waiting: idea.pending
        case .all: idea.pending || idea.status != .dropped
        case .new: !idea.pending && idea.status == .new
        case .researching: !idea.pending && idea.status == .researching
        case .researched: !idea.pending && idea.status == .researched
        case .dropped: !idea.pending && idea.status == .dropped
        }
    }
}

public enum IdeaGrouping {
    /// Groups in project-name order; ideas of an unknown project come last. Order within a
    /// group is kept as given (the hub's: starred, then by status, then newest).
    public static func byProject(_ ideas: [Idea], projects: [Project]) -> [(project: Project?, ideas: [Idea])] {
        let byId = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        var groups: [String: [Idea]] = [:]
        for idea in ideas {
            if groups[idea.projectId] == nil { order.append(idea.projectId) }
            groups[idea.projectId, default: []].append(idea)
        }
        let known = order.filter { byId[$0] != nil }
            .sorted { byId[$0]!.name.localizedCaseInsensitiveCompare(byId[$1]!.name) == .orderedAscending }
        let unknown = order.filter { byId[$0] == nil }
        return (known + unknown).map { (project: byId[$0], ideas: groups[$0] ?? []) }
    }
}
