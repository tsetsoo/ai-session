/// Status changes between two refreshes. Keyed by conversation (`listKey`), never by todo: a
/// todo can have several conversations (competing agents, worktrees), each with its own status.
public enum StatusTransitions {
    /// The `previous` argument for the next refresh: `listKey` to status.
    public static func snapshot(_ conversations: [Conversation]) -> [String: ConversationStatus] {
        Dictionary(conversations.map { ($0.listKey, $0.status) }, uniquingKeysWith: { _, new in new })
    }

    /// Conversations that just started waiting on the user: the only source of "needs you"
    /// alerts. `previous` is a `snapshot` of the last refresh; `nil` means this is the first
    /// snapshot after launch or after a reconnect, which never notifies (those prompts are old
    /// news). A conversation new since the last snapshot that is already waiting counts.
    public static func newlyWaiting(previous: [String: ConversationStatus]?, current: [Conversation]) -> [Conversation] {
        guard let previous else { return [] }
        return current.filter { $0.status == .waiting && previous[$0.listKey] != .waiting }
    }

    /// Conversations that just finished a turn: now `idle`, and `busy` or `waiting` in the last
    /// snapshot. The source of "ready for review" signals. `previous == nil` (first snapshot after
    /// launch or a reconnect) never counts, and neither does a conversation new since then.
    public static func newlyFinished(previous: [String: ConversationStatus]?, current: [Conversation]) -> [Conversation] {
        guard let previous else { return [] }
        return current.filter { conversation in
            guard conversation.status == .idle, let before = previous[conversation.listKey] else { return false }
            return before == .busy || before == .waiting
        }
    }
}
