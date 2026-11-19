import Foundation

/// The custom keys of a todo-server push (`todo_id`, `session_id`, `kind`), from a
/// notification's `userInfo`. `nil` for pushes that aren't about a todo (test pushes).
public struct PushPayload: Equatable, Sendable {
    public var todoId: String
    public var sessionId: String?
    public var kind: String?

    public init(todoId: String, sessionId: String? = nil, kind: String? = nil) {
        self.todoId = todoId
        self.sessionId = sessionId
        self.kind = kind
    }

    /// A "needs you" alert: opening it should show the chat, where its question can be answered.
    /// Other alerts ("done") leave the Chat/Terminal choice as it is.
    public var opensChat: Bool { kind == "waiting" }

    /// A reminder, date or briefing push (no todo): opening it shows Today.
    public static func isToday(userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["kind"] as? String) == "today"
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let todoId = userInfo["todo_id"] as? String, !todoId.isEmpty else { return nil }
        self.init(todoId: todoId, sessionId: userInfo["session_id"] as? String, kind: userInfo["kind"] as? String)
    }
}

/// The delivery identity required to act on a due reminder from a notification.
public struct ReminderPush: Equatable, Sendable {
    public enum Action: String, Encodable, Sendable {
        case done, snooze
    }

    public let id: String
    public let pushedAt: String

    public init?(userInfo: [AnyHashable: Any]) {
        guard PushPayload.isToday(userInfo: userInfo),
              let id = userInfo["reminder_id"] as? String, !id.isEmpty,
              let pushedAt = userInfo["reminder_pushed_at"] as? String, !pushedAt.isEmpty
        else { return nil }
        self.id = id
        self.pushedAt = pushedAt
    }
}
