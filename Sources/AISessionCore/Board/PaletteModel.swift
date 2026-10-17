import Foundation

/// A ⌘K palette command that isn't a place to go.
public enum PaletteAction: Equatable, Sendable {
    case newTodo
    /// Only for a selected todo without a conversation.
    case linkConversation(todoID: String, title: String)
    case newTodoFromConversation
    case openSettings

    public var title: String {
        switch self {
        case .newTodo: return "New todo"
        case let .linkConversation(_, title): return "Link a conversation to “\(title)”…"
        case .newTodoFromConversation: return "New todo from a conversation…"
        case .openSettings: return "Open Settings"
        }
    }
}

/// One palette row.
public enum PaletteItem: Equatable, Sendable, Identifiable {
    /// A Running-now conversation with its ⌘n (the first nine only).
    case conversation(Todo, Conversation, status: ConversationDisplayStatus, shortcut: Int?)
    /// A todo with no running conversation (none, or a closed one).
    case todo(Todo, conversation: Conversation?, status: ConversationDisplayStatus?)
    case project(Project)
    case action(PaletteAction)

    public var id: String {
        switch self {
        case let .conversation(todo, _, _, _): return "c:\(todo.id)"
        case let .todo(todo, _, _): return "t:\(todo.id)"
        case let .project(project): return "p:\(project.id)"
        case .action(.newTodo): return "a:newTodo"
        case let .action(.linkConversation(todoID, _)): return "a:link:\(todoID)"
        case .action(.newTodoFromConversation): return "a:newTodoFromConversation"
        case .action(.openSettings): return "a:openSettings"
        }
    }
}

public struct PaletteGroup: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case conversations, todos, projects, actions
    }

    public let kind: Kind
    public let items: [PaletteItem]

    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .conversations: return "Conversations"
        case .todos: return "Todos"
        case .projects: return "Projects"
        case .actions: return "Actions"
        }
    }
}

/// What the ⌘K palette lists for a query, and what ⌘1–⌘9 go to.
public enum PaletteModel {
    public static let maxPerGroup = 5

    /// Conversations (Running now, Needs you first), Todos (open ones without a running
    /// conversation), Projects, then the Actions. A query ranks each group by
    /// `PaletteMatcher.score` over title, section code and computer name (projects: name and
    /// folder); ties keep the empty-query order. An empty query lists only the conversations
    /// and the actions. Each group shows at most `maxPerGroup`; empty groups are left out.
    ///
    /// The actions are a short fixed list, so they stay whatever the query. `canEdit` false
    /// (offline, or no server) leaves only Open Settings.
    public static func groups(query: String, board: ConversationBoard, todos: [Todo], projects: [Project],
                              selectedTodoID: String?, canEdit: Bool) -> [PaletteGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let todosByID = Dictionary(todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let running = board.runningNow
        let shortcuts = Dictionary(running.prefix(9).enumerated().map { ($1.todoId, $0 + 1) },
                                   uniquingKeysWith: { first, _ in first })
        let needsYou = Set(board.needsYou.map(\.todoId))

        let conversationItems: [PaletteItem] = (board.needsYou + running.filter { !needsYou.contains($0.todoId) })
            .compactMap { conversation in
                guard let todo = todosByID[conversation.todoId] else { return nil }
                return .conversation(todo, conversation, status: board.status(forTodo: todo.id) ?? .idle,
                                     shortcut: shortcuts[todo.id])
            }

        var groups: [PaletteGroup] = []
        if query.isEmpty {
            groups.append(PaletteGroup(kind: .conversations, items: Array(conversationItems.prefix(maxPerGroup))))
        } else {
            let conversations = Dictionary(board.all.map { ($0.todoId, $0) }, uniquingKeysWith: { first, _ in first })
            let runningIDs = Set(running.map(\.todoId))
            let todoItems: [PaletteItem] = todos
                .filter { !$0.completed && !runningIDs.contains($0.id) }
                .map { todo in
                    let conversation = conversations[todo.id]
                    return .todo(todo, conversation: conversation,
                                 status: conversation == nil ? nil : board.status(forTodo: todo.id))
                }
            groups.append(PaletteGroup(kind: .conversations, items: ranked(conversationItems, query: query)))
            groups.append(PaletteGroup(kind: .todos, items: ranked(todoItems, query: query)))
            groups.append(PaletteGroup(kind: .projects, items: ranked(projects.map(PaletteItem.project), query: query)))
        }
        groups.append(PaletteGroup(kind: .actions, items: actions(
            selected: selectedTodoID.flatMap { todosByID[$0] }, board: board, canEdit: canEdit
        )))
        return groups.filter { !$0.items.isEmpty }
    }

    /// ⌘n: the n-th Running-now conversation's todo (1-based); nothing past the end.
    public static func shortcutTarget(_ n: Int, board: ConversationBoard, todos: [Todo]) -> Todo? {
        guard let conversation = board.conversation(atShortcut: n) else { return nil }
        return todos.first { $0.id == conversation.todoId }
    }

    // MARK: Ranking

    private static func ranked(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let scored = items.enumerated().compactMap { index, item -> (item: PaletteItem, score: Int, index: Int)? in
            let scores = fields(of: item).compactMap { PaletteMatcher.score(query: query, candidate: $0) }
            return scores.max().map { (item, $0, index) }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(maxPerGroup)
            .map(\.item)
    }

    private static func fields(of item: PaletteItem) -> [String] {
        switch item {
        case let .conversation(todo, conversation, _, _):
            return [todo.title, todo.section.rawValue, conversation.computer.name]
        case let .todo(todo, conversation, _):
            return [todo.title, todo.section.rawValue] + (conversation.map { [$0.computer.name] } ?? [])
        case let .project(project):
            return [project.name, project.folder]
        case .action:
            return []
        }
    }

    private static func actions(selected: Todo?, board: ConversationBoard, canEdit: Bool) -> [PaletteItem] {
        guard canEdit else { return [.action(.openSettings)] }
        var actions: [PaletteAction] = [.newTodo]
        if let selected, board.status(forTodo: selected.id) == nil {
            actions.append(.linkConversation(todoID: selected.id, title: selected.title))
        }
        actions += [.newTodoFromConversation, .openSettings]
        return actions.map(PaletteItem.action)
    }
}
