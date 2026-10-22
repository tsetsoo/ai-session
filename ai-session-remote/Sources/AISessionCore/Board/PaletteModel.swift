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
    /// An open conversation with its ⌘n (the first nine of the list on screen only).
    case conversation(Todo, Conversation, status: ConversationDisplayStatus, shortcut: Int?)
    /// A todo with no running conversation (none, or a closed one).
    case todo(Todo, conversation: Conversation?, status: ConversationDisplayStatus?)
    case project(Project)
    case action(PaletteAction)

    public var id: String {
        switch self {
        // One row per conversation: a duplicated one shares its todo with the original.
        case let .conversation(_, conversation, _, _): return "c:\(conversation.listKey)"
        case let .todo(todo, _, _): return "t:\(todo.id)"
        case let .project(project): return "p:\(project.id)"
        case .action(.newTodo): return "a:newTodo"
        case let .action(.linkConversation(todoID, _)): return "a:link:\(todoID)"
        case .action(.newTodoFromConversation): return "a:newTodoFromConversation"
        case .action(.openSettings): return "a:openSettings"
        }
    }

    /// The row's title: a conversation's carries its name ("Fix the import · duplicate").
    public var title: String {
        switch self {
        case let .conversation(todo, conversation, _, _):
            return RowText.conversationTitle(todoTitle: todo.title, label: conversation.label)
        case let .todo(todo, _, _): return todo.title
        case let .project(project): return project.name
        case let .action(action): return action.title
        }
    }
}

public struct PaletteGroup: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case conversations, todos, projects, actions
    }

    public let kind: Kind
    public let items: [PaletteItem]
    /// By item id: the characters of its title to bold, as character offsets. The match that
    /// ranked it, so absent when it matched on another field (or with no query).
    public let highlights: [String: [Range<Int>]]

    public init(kind: Kind, items: [PaletteItem], highlights: [String: [Range<Int>]] = [:]) {
        self.kind = kind
        self.items = items
        self.highlights = highlights
    }

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

    /// Conversations (the open ones, Needs you first), Todos (open ones without a running
    /// conversation), Projects, then the Actions. A query ranks each group by the best
    /// `PaletteMatch` over title, section code and computer name (conversations: also the tool;
    /// projects: name and folder):
    /// contiguous matches first, then scattered ones, which a query of three or more characters
    /// drops whenever something in the group matches contiguously. Ties keep the empty-query
    /// order. An empty query lists only the conversations and the actions. Each group shows at
    /// most `maxPerGroup`; empty groups are left out.
    ///
    /// The actions are a short fixed list, so they stay whatever the query. `canEdit` false
    /// (offline, or no server) leaves only Open Settings.
    /// - Parameter shortcutList: the list ⌘1–⌘9 number (the one on screen); the open
    ///   conversations by default.
    public static func groups(query: String, board: ConversationBoard, todos: [Todo], projects: [Project],
                              selectedTodoID: String?, canEdit: Bool,
                              shortcutList: [Conversation]? = nil) -> [PaletteGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let todosByID = Dictionary(todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let running = board.open
        let shortcuts = Dictionary((shortcutList ?? running).prefix(9).enumerated().map { ($1.listKey, $0 + 1) },
                                   uniquingKeysWith: { first, _ in first })
        let needsYou = Set(board.needsYou.map(\.listKey))

        let conversationItems: [PaletteItem] = (board.needsYou + running.filter { !needsYou.contains($0.listKey) })
            .compactMap { conversation in
                guard let todo = todosByID[conversation.todoId] else { return nil }
                return .conversation(todo, conversation, status: board.status(of: conversation),
                                     shortcut: shortcuts[conversation.listKey])
            }

        var groups: [PaletteGroup] = []
        if query.isEmpty {
            groups.append(PaletteGroup(kind: .conversations, items: Array(conversationItems.prefix(maxPerGroup))))
        } else {
            let conversations = Dictionary(grouping: board.all, by: \.todoId)
            let runningIDs = Set(running.map(\.todoId))
            let todoItems: [PaletteItem] = todos
                .filter { !$0.completed && !runningIDs.contains($0.id) }
                .map { todo in
                    let conversation = ConversationIndex.mostUrgent(conversations[todo.id] ?? [])
                    return .todo(todo, conversation: conversation,
                                 status: conversation == nil ? nil : board.status(forTodo: todo.id))
                }
            groups.append(ranked(conversationItems, kind: .conversations, query: query))
            groups.append(ranked(todoItems, kind: .todos, query: query))
            groups.append(ranked(projects.map(PaletteItem.project), kind: .projects, query: query))
        }
        groups.append(PaletteGroup(kind: .actions, items: actions(
            selected: selectedTodoID.flatMap { todosByID[$0] }, board: board, canEdit: canEdit
        )))
        return groups.filter { !$0.items.isEmpty }
    }

    /// ⌘n: the todo of the n-th conversation in `list` (1-based; the open conversations by
    /// default); nothing past the end.
    public static func shortcutTarget(_ n: Int, board: ConversationBoard, todos: [Todo],
                                      in list: [Conversation]? = nil) -> Todo? {
        guard let conversation = board.conversation(atShortcut: n, in: list) else { return nil }
        return todos.first { $0.id == conversation.todoId }
    }

    // MARK: Ranking

    private static func ranked(_ items: [PaletteItem], kind: PaletteGroup.Kind, query: String) -> PaletteGroup {
        var matched = items.enumerated().compactMap { index, item -> (item: PaletteItem, match: PaletteMatch, index: Int)? in
            fields(of: item).compactMap { PaletteMatch.best(query: query, candidate: $0) }.max()
                .map { (item, $0, index) }
        }
        if query.count >= 3, matched.contains(where: { $0.match.kind == .substring }) {
            matched.removeAll { $0.match.kind == .subsequence }
        }
        let shown = matched
            .sorted { $0.match != $1.match ? $0.match > $1.match : $0.index < $1.index }
            .prefix(maxPerGroup)
        var highlights: [String: [Range<Int>]] = [:]
        for (item, match, _) in shown {
            // The title's own match, of the kind that ranked the row.
            guard let title = fields(of: item).first,
                  let titleMatch = PaletteMatch.best(query: query, candidate: title),
                  titleMatch.kind == match.kind else { continue }
            highlights[item.id] = titleMatch.ranges
        }
        return PaletteGroup(kind: kind, items: shown.map(\.item), highlights: highlights)
    }

    /// The row's title first.
    private static func fields(of item: PaletteItem) -> [String] {
        switch item {
        case let .conversation(todo, conversation, _, _):
            return [item.title, todo.section.rawValue, conversation.computer.name,
                    RowText.toolName(conversation.tool)]
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

/// How a palette query matches one string. A contiguous match (case- and accent-insensitive)
/// always outranks a scattered one; within contiguous matches the start of the string, then
/// the start of a word, then an earlier position wins. Scattered matches rank by
/// `PaletteMatcher.score`.
public struct PaletteMatch: Comparable, Sendable {
    public enum Kind: Int, Sendable {
        case subsequence, substring
    }

    public let kind: Kind
    public let score: Int
    /// The matched characters, as character offsets into the candidate.
    public let ranges: [Range<Int>]

    public static func < (lhs: PaletteMatch, rhs: PaletteMatch) -> Bool {
        lhs.kind != rhs.kind ? lhs.kind.rawValue < rhs.kind.rawValue : lhs.score < rhs.score
    }

    public static func best(query: String, candidate: String) -> PaletteMatch? {
        let q = folded(query).characters
        guard !q.isEmpty else { return nil }
        let original = Array(candidate)
        let (c, origin) = folded(candidate)
        return substring(q, in: c, origin: origin, original: original)
            ?? subsequence(q, in: c, origin: origin, query: query, candidate: candidate)
    }

    private static func substring(_ q: [Character], in c: [Character], origin: [Int],
                                  original: [Character]) -> PaletteMatch? {
        guard c.count >= q.count else { return nil }
        var best: PaletteMatch?
        for start in 0...(c.count - q.count) where c[start..<start + q.count].elementsEqual(q) {
            let from = origin[start]
            let to = origin[start + q.count - 1] + 1
            let wordStart = from == 0 || !(original[from - 1].isLetter || original[from - 1].isNumber)
            let score = (from == 0 ? 150 : wordStart ? 100 : 0) - min(from, 50)
            if best == nil || score > best!.score {
                best = PaletteMatch(kind: .substring, score: score, ranges: [from..<to])
            }
        }
        return best
    }

    /// Greedy, like `PaletteMatcher`, whose score it carries.
    private static func subsequence(_ q: [Character], in c: [Character], origin: [Int],
                                    query: String, candidate: String) -> PaletteMatch? {
        guard let score = PaletteMatcher.score(query: query, candidate: candidate) else { return nil }
        var offsets: [Int] = []
        var ci = 0
        for ch in q {
            guard let hit = c[ci...].firstIndex(of: ch) else { return nil }
            if offsets.last != origin[hit] { offsets.append(origin[hit]) }
            ci = hit + 1
        }
        var ranges: [Range<Int>] = []
        for offset in offsets {
            if let last = ranges.last, last.upperBound == offset {
                ranges[ranges.count - 1] = last.lowerBound..<offset + 1
            } else {
                ranges.append(offset..<offset + 1)
            }
        }
        return PaletteMatch(kind: .subsequence, score: score, ranges: ranges)
    }

    /// Folded character by character, remembering each one's offset in the original.
    private static func folded(_ string: String) -> (characters: [Character], origin: [Int]) {
        var characters: [Character] = []
        var origin: [Int] = []
        for (offset, character) in string.enumerated() {
            for folded in String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
                characters.append(folded)
                origin.append(offset)
            }
        }
        return (characters, origin)
    }
}
