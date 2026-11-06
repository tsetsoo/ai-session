/// Why opening a conversation over SSH failed, from the helper script's exit status.
public enum OpenFailure: Equatable, Sendable {
    case helpersMissing, toolMissing, folderMissing, conversationNotFound
    /// Another Codex holds the conversation (its writer lock).
    case openElsewhere
    /// The conversation's own git worktree couldn't be made (`ai-todo-open --worktree`).
    case worktreeFailed

    public init?(exitStatus: Int?) {
        switch exitStatus {
        case 127: self = .helpersMissing
        case 90: self = .toolMissing
        case 93: self = .folderMissing
        case 94: self = .conversationNotFound
        case 95: self = .openElsewhere
        case 96: self = .worktreeFailed
        default: return nil
        }
    }
}
