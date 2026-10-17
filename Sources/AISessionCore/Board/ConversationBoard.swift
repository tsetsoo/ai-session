import Foundation

/// Derived view of todos and their conversations: what is running, what needs attention, counts.
public struct ConversationBoard: Sendable {
    private let todos: [Todo]
    private let conversations: [String: Conversation]
    private let liveTmux: [String: Set<String>]
    private let listedAt: [String: Date]
    private let running: [Conversation]

    /// - Parameters:
    ///   - conversations: keyed by todo id.
    ///   - liveTmux: computer id to its tmux session names; a computer that is absent is unknown.
    ///   - listedAt: computer id to when its `liveTmux` entry was listed. A conversation missing
    ///     from a listing older than its own last change (started or reported after it) is
    ///     unknown rather than closed. Without a date the listing counts as current.
    public init(todos: [Todo], conversations: [String: Conversation], liveTmux: [String: Set<String>],
                listedAt: [String: Date] = [:]) {
        self.todos = todos
        self.conversations = conversations
        self.liveTmux = liveTmux
        self.listedAt = listedAt
        self.running = conversations.values
            .filter { Self.display($0, liveTmux: liveTmux, listedAt: listedAt) != .closed }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.todoId < $1.todoId }
    }

    private static func display(_ c: Conversation, liveTmux: [String: Set<String>],
                                listedAt: [String: Date]) -> ConversationDisplayStatus {
        ConversationDisplayStatus(c.status, tmuxAlive: tmuxAlive(c, liveTmux: liveTmux, listedAt: listedAt))
    }

    /// `nil` (unknown) when the computer wasn't listed, or was listed before the conversation
    /// last changed and the listing doesn't have it.
    private static func tmuxAlive(_ c: Conversation, liveTmux: [String: Set<String>],
                                  listedAt: [String: Date]) -> Bool? {
        guard let names = liveTmux[c.computer.id] else { return nil }
        if names.contains(c.tmuxName) { return true }
        return isNewer(c, than: listedAt[c.computer.id]) ? nil : false
    }

    private static func isNewer(_ c: Conversation, than listed: Date?) -> Bool {
        guard let listed else { return false }
        let changed = [c.createdAt, c.statusUpdatedAt].compactMap { HubDates.date(from: $0) }.max()
        return changed.map { $0 > listed } ?? false
    }

    /// Conversations missing from their computer's listing that changed after it was taken:
    /// that computer needs listing again before they can count as closed.
    public var newerThanListing: [Conversation] {
        conversations.values.filter { c in
            guard let names = liveTmux[c.computer.id], !names.contains(c.tmuxName) else { return false }
            return Self.isNewer(c, than: listedAt[c.computer.id])
        }
    }

    public func status(forTodo id: String) -> ConversationDisplayStatus? {
        conversations[id].map { Self.display($0, liveTmux: liveTmux, listedAt: listedAt) }
    }

    /// `createdAt` is sortable UTC ISO-8601, so strings compare in time order.
    public var runningNow: [Conversation] { running }

    public var needsYou: [Conversation] {
        running.filter { Self.display($0, liveTmux: liveTmux, listedAt: listedAt) == .needsYou }
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
