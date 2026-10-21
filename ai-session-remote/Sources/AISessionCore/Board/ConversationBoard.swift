import Foundation

/// Derived view of todos and their conversations: what is running, what needs attention, counts.
///
/// Immutable. Each conversation's change date is parsed once here; the lists and counts are stored
/// so later reads do not scan or parse again. `AppModel` keeps one instance and replaces it only
/// when the inputs change.
public final class ConversationBoard: Sendable {
    private let running: [Conversation]
    private let closed: [Conversation]
    private let statusByTodoID: [String: ConversationDisplayStatus]
    private let statusByListKey: [String: ConversationDisplayStatus]
    private let openTodoCounts: [TodoSection: Int]
    private let sectionNeedsYouFlags: [TodoSection: Bool]
    private let runningCounts: [String: Int]
    private let needsYouCounts: [String: Int]

    /// - Parameters:
    ///   - conversations: keyed by conversation id.
    ///   - liveTmux: computer id to its tmux session names; a computer that is absent is unknown.
    ///   - listedAt: computer id to when its `liveTmux` entry was listed. A conversation missing
    ///     from a listing older than its own last change (started or reported after it) is
    ///     unknown rather than closed. Without a date the listing counts as current.
    public init(todos: [Todo], conversations: [String: Conversation], liveTmux: [String: Set<String>],
                listedAt: [String: Date] = [:]) {
        var statusByListKey: [String: ConversationDisplayStatus] = [:]
        statusByListKey.reserveCapacity(conversations.count)
        var byTodo: [String: [(Conversation, ConversationDisplayStatus)]] = [:]
        var open: [(Conversation, ConversationDisplayStatus)] = []
        open.reserveCapacity(conversations.count)
        var closedConversations: [Conversation] = []
        var newer: [Conversation] = []

        for conversation in conversations.values {
            let changed = Self.changeDate(conversation)
            let alive = Self.tmuxAlive(conversation, changed: changed, liveTmux: liveTmux, listedAt: listedAt)
            let status = ConversationDisplayStatus(conversation.status, tmuxAlive: alive)
            statusByListKey[conversation.listKey] = status
            byTodo[conversation.todoId, default: []].append((conversation, status))
            if status == .closed {
                closedConversations.append(conversation)
            } else {
                open.append((conversation, status))
            }
            if Self.isNewerThanListing(conversation, changed: changed, liveTmux: liveTmux, listedAt: listedAt) {
                newer.append(conversation)
            }
        }
        open.sort { Self.newestFirst($0.0, $1.0) }
        closedConversations.sort(by: Self.newestFirst)

        var statuses: [String: ConversationDisplayStatus] = [:]
        for (todoId, rows) in byTodo {
            guard let winner = ConversationIndex.mostUrgent(rows.map(\.0)) else { continue }
            statuses[todoId] = rows.first { $0.0 == winner }?.1
        }

        var needing: [Conversation] = []
        var runningByComputer: [String: Int] = [:]
        var needsByComputer: [String: Int] = [:]
        for (conversation, status) in open {
            runningByComputer[conversation.computer.id, default: 0] += 1
            if status == .needsYou {
                needing.append(conversation)
                needsByComputer[conversation.computer.id, default: 0] += 1
            }
        }

        var openCounts = Dictionary(uniqueKeysWithValues: TodoSection.allCases.map { ($0, 0) })
        var needsSection = Dictionary(uniqueKeysWithValues: TodoSection.allCases.map { ($0, false) })
        for todo in todos {
            if !todo.completed { openCounts[todo.section, default: 0] += 1 }
            if statuses[todo.id] == .needsYou { needsSection[todo.section] = true }
        }

        self.running = open.map(\.0)
        self.closed = closedConversations
        self.needsYou = needing
        self.newerThanListing = newer
        self.statusByTodoID = statuses
        self.statusByListKey = statusByListKey
        self.openTodoCounts = openCounts
        self.sectionNeedsYouFlags = needsSection
        self.runningCounts = runningByComputer
        self.needsYouCounts = needsByComputer
    }

    /// The later of `createdAt` and `statusUpdatedAt`, parsed once per conversation.
    private static func changeDate(_ conversation: Conversation) -> Date? {
        [conversation.createdAt, conversation.statusUpdatedAt].compactMap { HubDates.date(from: $0) }.max()
    }

    /// `nil` (unknown) when the computer wasn't listed, or was listed before the conversation
    /// last changed and the listing doesn't have it.
    private static func tmuxAlive(_ conversation: Conversation, changed: Date?,
                                  liveTmux: [String: Set<String>], listedAt: [String: Date]) -> Bool? {
        guard let names = liveTmux[conversation.computer.id] else { return nil }
        if names.contains(conversation.tmuxName) { return true }
        guard let changed, let listed = listedAt[conversation.computer.id], changed > listed else { return false }
        return nil
    }

    private static func isNewerThanListing(_ conversation: Conversation, changed: Date?,
                                           liveTmux: [String: Set<String>], listedAt: [String: Date]) -> Bool {
        if liveTmux[conversation.computer.id]?.contains(conversation.tmuxName) == true { return false }
        guard let changed, let listed = listedAt[conversation.computer.id], changed > listed else { return false }
        // Missing from the name set, or the computer never answered (no name set at all).
        return true
    }

    /// `createdAt` is sortable UTC ISO-8601, so strings compare in time order.
    private static func newestFirst(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.todoId < rhs.todoId
    }

    public func status(forTodo id: String) -> ConversationDisplayStatus? {
        statusByTodoID[id]
    }

    /// This conversation's own status, including a dead tmux session.
    public func status(of conversation: Conversation) -> ConversationDisplayStatus {
        statusByListKey[conversation.listKey] ?? .idle
    }

    /// `createdAt` is sortable UTC ISO-8601, so strings compare in time order.
    public var runningNow: [Conversation] { running }

    public let needsYou: [Conversation]

    /// Conversations missing from their computer's listing that changed after it was taken:
    /// that computer needs listing again before they can count as closed.
    public let newerThanListing: [Conversation]

    /// Running now, then the closed conversations, newest first. Both lists are stored
    /// with the snapshot, so a list refresh does not sort the closed rows again.
    public var all: [Conversation] { running + closed }

    /// 1-based; only the first nine get a keyboard shortcut.
    public func conversation(atShortcut n: Int) -> Conversation? {
        guard (1...9).contains(n), n <= running.count else { return nil }
        return running[n - 1]
    }

    public func openTodoCount(_ section: TodoSection) -> Int {
        openTodoCounts[section] ?? 0
    }

    public func sectionNeedsYou(_ section: TodoSection) -> Bool {
        sectionNeedsYouFlags[section] ?? false
    }

    public func runningCount(computerID: String) -> Int {
        runningCounts[computerID] ?? 0
    }

    public func needsYouCount(computerID: String) -> Int {
        needsYouCounts[computerID] ?? 0
    }
}
