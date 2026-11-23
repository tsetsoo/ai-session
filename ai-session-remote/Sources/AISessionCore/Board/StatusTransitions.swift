public enum StatusTransitions {
    /// Conversations that just started waiting on the user: the only source of "needs you"
    /// alerts. `previous` is todo id to the status in the last snapshot; `nil` means this is the
    /// first snapshot after launch or after a reconnect, which never notifies (those prompts are
    /// old news). A conversation new since the last snapshot that is already waiting counts.
    public static func newlyWaiting(previous: [String: ConversationStatus]?, current: [Conversation]) -> [Conversation] {
        guard let previous else { return [] }
        return current.filter { $0.status == .waiting && previous[$0.todoId] != .waiting }
    }

    /// Conversations that just finished a turn: now `idle`, and `busy` or `waiting` in the last
    /// snapshot. The source of "ready for review" signals. `previous == nil` (first snapshot after
    /// launch or a reconnect) never counts, and neither does a conversation new since then.
    public static func newlyFinished(previous: [String: ConversationStatus]?, current: [Conversation]) -> [Conversation] {
        guard let previous else { return [] }
        return current.filter { conversation in
            guard conversation.status == .idle, let before = previous[conversation.todoId] else { return false }
            return before == .busy || before == .waiting
        }
    }
}
