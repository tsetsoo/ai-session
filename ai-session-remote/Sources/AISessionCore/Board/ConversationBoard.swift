import Foundation

/// Derived view of todos and their conversations: what is open, working, waiting for review or
/// needs attention, and counts.
///
/// Immutable. Each conversation's change date is parsed once here; the lists and counts are stored
/// so later reads do not scan or parse again. `AppModel` keeps one instance and replaces it only
/// when the inputs change.
public final class ConversationBoard: Sendable {
    private let closed: [Conversation]
    private let statusByTodoID: [String: ConversationDisplayStatus]
    private let statusByListKey: [String: ConversationDisplayStatus]
    private let openTodoCounts: [TodoSection: Int]
    private let sectionNeedsYouFlags: [TodoSection: Bool]
    private let openCounts: [String: Int]
    private let workingCounts: [String: Int]
    private let reviewCounts: [String: Int]
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
        var changedByListKey: [String: Date] = [:]
        // The lists and counts leave out a conversation whose todo isn't loaded (an archived
        // todo): its row would have no title to show. Its status is still known.
        let todoIDs = Set(todos.lazy.map(\.id))

        for conversation in conversations.values {
            let changed = Self.changeDate(conversation)
            changedByListKey[conversation.listKey] = changed
            let alive = Self.tmuxAlive(conversation, changed: changed, liveTmux: liveTmux, listedAt: listedAt)
            let status = ConversationDisplayStatus(conversation.status, tmuxAlive: alive, reviewed: conversation.reviewed)
            statusByListKey[conversation.listKey] = status
            byTodo[conversation.todoId, default: []].append((conversation, status))
            if !todoIDs.contains(conversation.todoId) {
                // Not listed.
            } else if status == .closed {
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

        // A done todo's finished conversation has nothing left to review.
        let doneTodoIDs = Set(todos.lazy.filter(\.completed).map(\.id))
        var needing: [Conversation] = []
        var working: [Conversation] = []
        var review: [Conversation] = []
        var openByComputer: [String: Int] = [:]
        var workingByComputer: [String: Int] = [:]
        var reviewByComputer: [String: Int] = [:]
        var needsByComputer: [String: Int] = [:]
        for (conversation, status) in open {
            let computer = conversation.computer.id
            openByComputer[computer, default: 0] += 1
            switch status {
            case .needsYou:
                needing.append(conversation)
                needsByComputer[computer, default: 0] += 1
            case .working:
                working.append(conversation)
                workingByComputer[computer, default: 0] += 1
            case .idle:
                guard !doneTodoIDs.contains(conversation.todoId) else { break }
                review.append(conversation)
                reviewByComputer[computer, default: 0] += 1
            case .ready, .closed:
                break
            }
        }
        // Most recently finished first; `open`'s newest-first order breaks ties.
        review = review.enumerated().sorted { lhs, rhs in
            let l = changedByListKey[lhs.element.listKey] ?? .distantPast
            let r = changedByListKey[rhs.element.listKey] ?? .distantPast
            return l != r ? l > r : lhs.offset < rhs.offset
        }.map(\.element)

        var openTodos = Dictionary(uniqueKeysWithValues: TodoSection.allCases.map { ($0, 0) })
        var needsSection = Dictionary(uniqueKeysWithValues: TodoSection.allCases.map { ($0, false) })
        for todo in todos {
            if !todo.completed { openTodos[todo.section, default: 0] += 1 }
            if statuses[todo.id] == .needsYou { needsSection[todo.section] = true }
        }

        self.open = open.map(\.0)
        self.closed = closedConversations
        self.needsYou = needing
        self.working = working
        self.review = review
        self.newerThanListing = newer
        self.statusByTodoID = statuses
        self.statusByListKey = statusByListKey
        self.openTodoCounts = openTodos
        self.sectionNeedsYouFlags = needsSection
        self.openCounts = openByComputer
        self.workingCounts = workingByComputer
        self.reviewCounts = reviewByComputer
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

    /// Every conversation whose session is open, whatever its status, newest first.
    public let open: [Conversation]

    /// Stopped on a permission prompt, newest first.
    public let needsYou: [Conversation]

    /// The agent is busy, newest first.
    public let working: [Conversation]

    /// The turn ended (or no status yet): waiting for you to read it, unless its todo is done.
    /// Most recently changed first.
    public let review: [Conversation]

    /// Conversations missing from their computer's listing that changed after it was taken:
    /// that computer needs listing again before they can count as closed.
    public let newerThanListing: [Conversation]

    /// The open conversations, then the closed ones, newest first. Both lists are stored
    /// with the snapshot, so a list refresh does not sort the closed rows again.
    public var all: [Conversation] { open + closed }

    /// 1-based into `list` (the open conversations by default); only the first nine get a
    /// keyboard shortcut.
    public func conversation(atShortcut n: Int, in list: [Conversation]? = nil) -> Conversation? {
        let list = list ?? open
        guard (1...9).contains(n), n <= list.count else { return nil }
        return list[n - 1]
    }

    public func openTodoCount(_ section: TodoSection) -> Int {
        openTodoCounts[section] ?? 0
    }

    public func sectionNeedsYou(_ section: TodoSection) -> Bool {
        sectionNeedsYouFlags[section] ?? false
    }

    public func openCount(computerID: String) -> Int {
        openCounts[computerID] ?? 0
    }

    public func workingCount(computerID: String) -> Int {
        workingCounts[computerID] ?? 0
    }

    public func reviewCount(computerID: String) -> Int {
        reviewCounts[computerID] ?? 0
    }

    public func needsYouCount(computerID: String) -> Int {
        needsYouCounts[computerID] ?? 0
    }
}
