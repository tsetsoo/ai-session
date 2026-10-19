import Foundation

/// The tool step shown before a todo's first conversation. Claude is the preselection when
/// this device has not started one, and a preselection is not a start.
public enum ConversationStart {
    public static let storageKey = "lastStartedTool"

    /// `remembered` when it is a tool this app can start, otherwise Claude.
    public static func selectedTool(remembered: String?) -> String {
        guard let remembered, remembered == "claude" || remembered == "codex" || remembered == "cursor" else {
            return "claude"
        }
        return remembered
    }

    /// A conversation has started only once it has the id the tool is using. An empty id is a
    /// start that did not finish, and the tool step asks again.
    public static func hasStartedSession(_ sessionId: String?) -> Bool {
        guard let sessionId else { return false }
        return !sessionId.isEmpty
    }

    /// A todo with no conversation asks before anything is created. One that already has a
    /// conversation resumes it.
    public static func needsConfirm(hasConversation: Bool) -> Bool {
        !hasConversation
    }

    /// Codex and Cursor mint their own id. Claude's id is already on the hub.
    public static func startsFresh(_ tool: String) -> Bool {
        tool == "codex" || tool == "cursor"
    }

    /// The id printed by a detached `ai-todo-open` (`created <id>`). Missing or blank is nil.
    public static func createdSessionId(from output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0] == "created" else { continue }
            let id = parts[1].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { return id }
        }
        return nil
    }
}
