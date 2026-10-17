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

    /// Whether to post a local alert for a conversation that just turned `waiting`.
    /// - Never while that conversation is on screen.
    /// - iPhone: only when the server's push isn't covering it.
    /// - Mac: only when no iPhone receives pushes (the iPhone's alert also shows on the Mac with
    ///   iPhone Mirroring), unless "Alert on this Mac too" is on.
    public static func shouldPostLocal(
        pushState: PushState,
        visibleTodoId: String?,
        todoId: String,
        isMac: Bool,
        iPhoneRegisteredOnServer: Bool,
        macAlertsToo: Bool
    ) -> Bool {
        if visibleTodoId == todoId { return false }
        if isMac { return !iPhoneRegisteredOnServer || macAlertsToo }
        return pushState != .registered
    }
}
