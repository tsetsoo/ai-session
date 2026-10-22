import Foundation

/// How the phone's Todos tab groups todos: by section (with its computer), by project, or by
/// what the todo's conversation is doing.
public enum TodoGrouping: String, CaseIterable, Sendable {
    case section, project, status

    public var label: String {
        switch self {
        case .section: "Section"
        case .project: "Project"
        case .status: "Status"
        }
    }

    /// Open todos of one project, newest first; `project` is nil for todos without one (or
    /// whose project is gone).
    public struct ProjectGroup: Equatable, Identifiable, Sendable {
        public var project: Project?
        public var todos: [Todo]

        public var id: String { project?.id ?? "" }
        public var title: String { project?.name ?? "No project" }
    }

    /// What a todo's conversation is doing, in the Conversations tab's order.
    public enum Status: String, CaseIterable, Sendable, Identifiable {
        case needsYou, review, working, noConversation

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .needsYou: "Needs you"
            case .review: "Ready for review"
            case .working: "Working"
            case .noConversation: "No conversation"
            }
        }

        /// A closed conversation counts as none.
        public init(_ status: ConversationDisplayStatus?) {
            switch status {
            case .needsYou: self = .needsYou
            case .idle: self = .review
            case .working: self = .working
            case .closed, nil: self = .noConversation
            }
        }
    }

    public struct StatusGroup: Equatable, Identifiable, Sendable {
        public var status: Status
        public var todos: [Todo]

        public var id: String { status.id }
    }

    /// One group per project with open todos, projects by name, then "No project". Done todos
    /// are left out.
    public static func byProject(_ todos: [Todo], projects: [Project]) -> [ProjectGroup] {
        let known = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byProject = Dictionary(grouping: todos.filter { !$0.completed }) { todo in
            todo.projectId.flatMap { known[$0] == nil ? nil : $0 } ?? ""
        }
        let named = projects
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .compactMap { project -> ProjectGroup? in
                guard let items = byProject[project.id], !items.isEmpty else { return nil }
                return ProjectGroup(project: project, todos: newestFirst(items))
            }
        guard let loose = byProject[""], !loose.isEmpty else { return named }
        return named + [ProjectGroup(project: nil, todos: newestFirst(loose))]
    }

    /// One group per status with open todos, in `Status.allCases` order. Done todos are left out.
    public static func byStatus(_ todos: [Todo],
                                status: (String) -> ConversationDisplayStatus?) -> [StatusGroup] {
        let byStatus = Dictionary(grouping: todos.filter { !$0.completed }) { Status(status($0.id)) }
        return Status.allCases.compactMap { status in
            guard let items = byStatus[status], !items.isEmpty else { return nil }
            return StatusGroup(status: status, todos: newestFirst(items))
        }
    }

    /// Newest first, then by id so the order is stable.
    static func newestFirst(_ todos: [Todo]) -> [Todo] {
        todos.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
    }
}
