import Foundation

/// The name offered when duplicating a conversation: "duplicate", then "duplicate 2", and so on.
public enum DuplicateName {
    public static func proposal(existingLabels: [String]) -> String {
        if !existingLabels.contains("duplicate") { return "duplicate" }
        var n = 2
        while existingLabels.contains("duplicate \(n)") { n += 1 }
        return "duplicate \(n)"
    }
}

/// Which conversation of a todo is the one to open, and the status that todo shows.
public enum ConversationIndex {
    /// Needs you, then working, then unread idle, then ready, then closed. A tie goes to the later status
    /// change, then the later start, then the smaller id.
    public static func mostUrgent(_ conversations: [Conversation]) -> Conversation? {
        conversations.min { left, right in
            let leftRank = urgency(left)
            let rightRank = urgency(right)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftAt = left.statusUpdatedAt ?? ""
            let rightAt = right.statusUpdatedAt ?? ""
            if leftAt != rightAt { return leftAt > rightAt }
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id < right.id
        }
    }

    private static func urgency(_ conversation: Conversation) -> Int {
        switch conversation.status {
        case .waiting: return 0
        case .busy: return 1
        case .idle: return conversation.reviewed ? 3 : 2
        case .unknown: return 3
        case .closed: return 4
        }
    }
}
