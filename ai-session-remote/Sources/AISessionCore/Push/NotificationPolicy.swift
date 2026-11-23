import Foundation

/// Where this device's "needs you" alerts come from.
public enum PushState: Equatable, Sendable {
    /// Notifications are switched off in Settings (or permission was denied).
    case off
    /// No remote push (old server, Mac, registration failed): local alerts while the app runs.
    case localOnly(String)
    /// Registered with the server: its push is the alert.
    case registered
}

/// Rules shared by local and remote alerts, kept here so they can be tested.
public enum NotificationPolicy {
    /// Identifier of a todo's alert. Equal to the server's `apns-collapse-id`, so a newer alert
    /// for a todo (local or remote) replaces the older one instead of stacking.
    public static func notificationIdentifier(todoId: String) -> String {
        "todo-\(todoId)"
    }

    /// Delivered "needs you" alerts whose conversation no longer waits (answered elsewhere).
    /// "Done" alerts stay: they are about idle conversations by definition.
    public static func staleAlertIdentifiers(delivered: [PushPayload], waitingTodoIds: Set<String>) -> [String] {
        delivered
            .filter { $0.kind == "waiting" && !waitingTodoIds.contains($0.todoId) }
            .map { notificationIdentifier(todoId: $0.todoId) }
    }

    /// Whether the iPhone posts a local alert for a conversation that just turned `waiting`:
    /// never while that todo is on screen, and only when the server's push isn't covering it.
    /// (The Mac has its own rule: `NotificationCenterCoordinator.postAttention`.)
    public static func shouldPostLocal(pushState: PushState, visibleTodoId: String?, todoId: String) -> Bool {
        if visibleTodoId == todoId { return false }
        return pushState != .registered
    }

    /// The Mac's arrival banner for one conversation: siblings on the same todo, and a review
    /// banner versus a still-unseen Needs you banner of another conversation, never replace
    /// each other.
    public static func attentionIdentifier(conversationKey: String) -> String {
        "attention-\(conversationKey)"
    }

    /// Delivered Mac arrival banners whose conversation is no longer in the section the banner
    /// announced (answered, reviewed, working again, closed).
    public static func staleAttentionIdentifiers(delivered: [AttentionBanner], needsYou: Set<String>,
                                                 review: Set<String>) -> [String] {
        delivered.filter { banner in
            let section = banner.kind == "review" ? review : needsYou
            return !section.contains(banner.conversationKey)
        }
        .map(\.identifier)
    }
}

/// A delivered Mac arrival banner, read back from its request (`conversation_key` in userInfo).
public struct AttentionBanner: Equatable, Sendable {
    public var identifier: String
    /// `"waiting"` (Needs you) or `"review"`.
    public var kind: String
    public var conversationKey: String

    public init(identifier: String, kind: String, conversationKey: String) {
        self.identifier = identifier
        self.kind = kind
        self.conversationKey = conversationKey
    }

    public init?(identifier: String, userInfo: [AnyHashable: Any]) {
        guard let key = userInfo["conversation_key"] as? String, !key.isEmpty,
              let kind = userInfo["kind"] as? String else { return nil }
        self.init(identifier: identifier, kind: kind, conversationKey: key)
    }
}
