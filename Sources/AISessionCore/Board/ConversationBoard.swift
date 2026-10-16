/// Derived view of todos and their conversations: what is running, what needs attention, counts.
public struct ConversationBoard: Sendable {
    private let todos: [Todo]
    private let conversations: [String: Conversation]
    private let liveTmux: [String: Set<String>]
    private let running: [Conversation]

    /// - Parameters:
    ///   - conversations: keyed by todo id.
    ///   - liveTmux: computer id to its tmux session names; a computer that is absent is unknown.
    public init(todos: [Todo], conversations: [String: Conversation], liveTmux: [String: Set<String>]) {
        self.todos = todos
        self.conversations = conversations
        self.liveTmux = liveTmux
        self.running = conversations.values
            .filter { Self.display($0, liveTmux: liveTmux) != .closed }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.todoId < $1.todoId }
    }

    private static func display(_ c: Conversation, liveTmux: [String: Set<String>]) -> ConversationDisplayStatus {
        ConversationDisplayStatus(c.status, tmuxAlive: liveTmux[c.computer.id].map { $0.contains(c.tmuxName) })
    }

    public func status(forTodo id: String) -> ConversationDisplayStatus? {
        conversations[id].map { Self.display($0, liveTmux: liveTmux) }
    }

    /// `createdAt` is sortable UTC ISO-8601, so strings compare in time order.
    public var runningNow: [Conversation] { running }

    public var needsYou: [Conversation] {
        running.filter { Self.display($0, liveTmux: liveTmux) == .needsYou }
    }

    /// 1-based; only the first nine get a keyboard shortcut.
    public func conversation(atShortcut n: Int) -> Conversation? {
        guard (1...9).contains(n), n <= running.count else { return nil }
        return running[n - 1]
    }

    public func openTodoCount(_ section: TodoSection) -> Int {
        todos.filter { $0.section == section && !$0.completed }.count
    }

    public func sectionNeedsYou(_ section: TodoSection) -> Bool {
        todos.contains { $0.section == section && status(forTodo: $0.id) == .needsYou }
    }

    public func runningCount(computerID: String) -> Int {
        running.filter { $0.computer.id == computerID }.count
    }
}
