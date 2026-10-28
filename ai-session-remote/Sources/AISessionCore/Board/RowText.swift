import Foundation

/// Secondary-line copy for the Todos, Conversations and Computers list rows.
public enum RowText {
    /// "1 needs you · 2 to review · 3 working", any part left out at zero, or "No open conversations".
    public static func computerLine(working: Int, review: Int, needsYou: Int) -> String {
        let parts = [
            needsYou > 0 ? "\(needsYou) needs you" : nil,
            review > 0 ? "\(review) to review" : nil,
            working > 0 ? "\(working) working" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? "No open conversations" : parts.joined(separator: " · ")
    }

    /// The todo delete confirmation's message. The hub deletes a todo's conversations with it,
    /// but nothing on the computers: a session still open there keeps running.
    public static func todoDeleteMessage(conversations: [Conversation]) -> String {
        guard !conversations.isEmpty else { return "This can't be undone." }
        let removed = conversations.count == 1 ? "Its conversation is removed with it." : "Its \(conversations.count) conversations are removed with it."
        var computers: [String] = []
        for conversation in conversations where conversation.status != .closed
            && !computers.contains(conversation.computer.name) {
            computers.append(conversation.computer.name)
        }
        guard !computers.isEmpty else { return "\(removed) This can't be undone." }
        return "\(removed) A session still open on \(computers.joined(separator: " or ")) keeps running there. This can't be undone."
    }

    public static func toolName(_ tool: String) -> String {
        switch tool {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "shell": return "Shell"
        default: return tool
        }
    }

    /// "{todo title} · {name}" when the conversation was named, otherwise the todo title.
    public static func conversationTitle(todoTitle: String, label: String?) -> String {
        guard let label else { return todoTitle }
        return "\(todoTitle) · \(label)"
    }

    /// "Sp · mac-studio". The tool is the row's icon, not this line.
    public static func conversationMeta(_ conversation: Conversation, section: TodoSection?) -> String {
        [section?.rawValue, conversation.computer.name].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Sp · mac-studio · ~/repo". The tool is the terminal band, not this line.
    public static func frameSubtitle(section: TodoSection, computer: String, folder: String?) -> String {
        var parts = [section.rawValue, computer]
        if let folder { parts.append(folder) }
        return parts.joined(separator: " · ")
    }

    /// The gray line plus the tool name, so a search for "Claude" still hits the row.
    public static func conversationSearchText(_ conversation: Conversation, section: TodoSection?) -> String {
        [conversationMeta(conversation, section: section), toolName(conversation.tool)].joined(separator: " ")
    }

    /// Time since the conversation last changed status (or started): "now", "4m", "1h", "3d".
    public static func age(of conversation: Conversation, now: Date) -> String? {
        guard let since = date(conversation.statusUpdatedAt) ?? date(conversation.createdAt) else { return nil }
        return shortInterval(now.timeIntervalSince(since))
    }

    /// The conversation row's last line: the status message when it needs you, else how long it
    /// has been working or since its turn finished, or the status.
    public static func conversationMessage(_ conversation: Conversation, status: ConversationDisplayStatus,
                                           now: Date) -> String {
        switch status {
        case .needsYou:
            return message(conversation) ?? "Waiting for you"
        case .working:
            guard let since = date(conversation.statusUpdatedAt) else { return "Working" }
            let elapsed = now.timeIntervalSince(since)
            return elapsed < 60 ? "Working" : "Working for \(shortInterval(elapsed))"
        case .idle:
            guard let since = date(conversation.statusUpdatedAt) else { return status.label }
            let elapsed = now.timeIntervalSince(since)
            return elapsed < 60 ? "Finished just now" : "Finished \(shortInterval(elapsed)) ago"
        case .ready, .closed:
            return status.label
        }
    }

    /// A todo row's second line: the status message when it needs you, else "mac-studio · 3m".
    /// `nil` without a conversation.
    public static func todoSubtitle(_ conversation: Conversation?, status: ConversationDisplayStatus?,
                                    now: Date) -> String? {
        guard let conversation, let status else { return nil }
        if status == .needsYou, let message = message(conversation) { return message }
        return [conversation.computer.name, age(of: conversation, now: now)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private static func message(_ conversation: Conversation) -> String? {
        guard let text = conversation.statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func shortInterval(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }

    private static let plainDates = ISO8601DateFormatter()
    private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return plainDates.date(from: iso) ?? fractionalDates.date(from: iso)
    }
}
