public enum StatusTransitions {
    /// Conversations that just started waiting on the user: the only source of "needs you"
    /// alerts. `previous` is todo id to the status in the last snapshot; `nil` means this is the
    /// first snapshot after launch or after a reconnect, which never notifies (those prompts are
    /// old news). A conversation new since the last snapshot that is already waiting counts.
    public static func newlyWaiting(previous: [String: ConversationStatus]?, current: [Conversation]) -> [Conversation] {
        guard let previous else { return [] }
        return current.filter { $0.status == .waiting && previous[$0.todoId] != .waiting }
    }
}
