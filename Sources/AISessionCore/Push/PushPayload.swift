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

    public init?(userInfo: [AnyHashable: Any]) {
        guard let todoId = userInfo["todo_id"] as? String, !todoId.isEmpty else { return nil }
        self.init(todoId: todoId, sessionId: userInfo["session_id"] as? String, kind: userInfo["kind"] as? String)
    }
}
