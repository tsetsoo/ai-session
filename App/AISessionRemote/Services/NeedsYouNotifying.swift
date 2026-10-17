import Foundation
import UserNotifications

/// What the redesign needs from the notification owner: post a "needs you" alert, report the
/// conversation on screen, route a tapped alert, and the Settings switches. The signatures match
/// the push-notifications work's `NotificationCenterCoordinator`.
///
/// Replaced by NotificationCenterCoordinator when the push-notifications work lands on main.
@MainActor
protocol NeedsYouNotifying: AnyObject {
    func postWaiting(todoId: String, sessionId: String, title: String, body: String)
    /// Called with the todo ID when an alert is tapped.
    var onOpenTodo: ((String) -> Void)? { get set }
    /// The conversation frontmost on screen, if any; it is never alerted about.
    func setVisibleConversation(todoId: String?)
    /// Asks for permission when turning on; false means it stays off.
    func setNeedsYouEnabled(_ on: Bool) async -> Bool
    func setMuted(todoId: String, _ muted: Bool) async throws
    /// Whether rows offer Mute Notifications.
    var supportsMuting: Bool { get }
    /// The line under the Settings toggle.
    var pushStatusText: String? { get }
}

enum NeedsYouSettings {
    /// `@AppStorage` key of the "Notify me when a conversation needs me" switch. Off by default.
    static let enabledKey = "notify.needsYou"
}

/// The parts of `UNUserNotificationCenter` the local notifier uses; tests substitute a fake.
protocol LocalNotificationScheduling: AnyObject {
    func add(_ request: UNNotificationRequest) async throws
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

extension UNUserNotificationCenter: LocalNotificationScheduling {}

/// On-device alerts until the push-notifications work lands. Permission is only asked when the
/// Settings switch is turned on, never at launch. Muting is not supported.
///
/// Replaced by NotificationCenterCoordinator when the push-notifications work lands on main.
@MainActor
final class LocalNeedsYouNotifier: NeedsYouNotifying {
    var onOpenTodo: ((String) -> Void)?
    let supportsMuting = false
    let pushStatusText: String? = "Alerts come from this device."

    private(set) var visibleTodoId: String?
    private let defaults: UserDefaults
    /// Resolved on first use, so creating the notifier (every `AppModel`, every test) never
    /// touches the notification center.
    private let makeCenter: () -> LocalNotificationScheduling
    private lazy var center: LocalNotificationScheduling = makeCenter()

    init(
        defaults: UserDefaults = .standard,
        center: @escaping () -> LocalNotificationScheduling = { UNUserNotificationCenter.current() }
    ) {
        self.defaults = defaults
        self.makeCenter = center
    }

    var isEnabled: Bool { defaults.bool(forKey: NeedsYouSettings.enabledKey) }

    func postWaiting(todoId: String, sessionId: String, title: String, body: String) {
        guard shouldPost(todoId: todoId) else { return }
        let request = Self.request(todoId: todoId, title: title, body: body)
        let center = center
        Task { try? await center.add(request) }
    }

    func setVisibleConversation(todoId: String?) {
        visibleTodoId = todoId
    }

    func setNeedsYouEnabled(_ on: Bool) async -> Bool {
        guard on else {
            defaults.set(false, forKey: NeedsYouSettings.enabledKey)
            return true
        }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        defaults.set(granted, forKey: NeedsYouSettings.enabledKey)
        return granted
    }

    func setMuted(todoId: String, _ muted: Bool) async throws {}

    /// Only when the switch is on and the conversation isn't the one on screen.
    func shouldPost(todoId: String) -> Bool {
        isEnabled && visibleTodoId != todoId
    }

    /// Same identifier, thread and payload key as the coordinator's alerts, so a later alert for
    /// the same todo replaces this one.
    static func request(todoId: String, title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = todoId
        content.userInfo = ["todo_id": todoId]
        return UNNotificationRequest(identifier: "todo-\(todoId)", content: content, trigger: nil)
    }
}
