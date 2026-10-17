public enum StatusTransitions {
    /// Conversations that just started waiting on the user. `previous` is todo id to the status in
    /// the last snapshot; `nil` means this is the first snapshot, which never notifies.
    public static func newlyWaiting(previous: [String: ConversationStatus]?, current: [Conversation]) -> [Conversation] {
        guard let previous else { return [] }
        return current.filter { $0.status == .waiting && previous[$0.todoId] != .waiting }
    }
}
