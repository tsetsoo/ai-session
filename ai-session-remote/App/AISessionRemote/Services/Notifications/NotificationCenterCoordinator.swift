import AISessionCore
import Foundation
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Notification.Name {
    /// The todo server URL or token changed: re-register for push with the new server.
    static let todoHubSettingsChanged = Notification.Name("AISessionRemote.todoHubSettingsChanged")
    /// A notification tap is opening a todo: show the Todos tab.
    static let todoNotificationOpened = Notification.Name("AISessionRemote.todoNotificationOpened")
}

/// The one owner of notifications: permission, categories, tap routing, local alerts,
/// remote push registration and "viewing this conversation" presence.
///
/// - Push registered: the todo-server's push is the "needs you" alert; local ones are skipped.
/// - Otherwise (old server, Mac, registration failed): local alerts while the app runs.
/// - Both use the identifier `todo-<todoId>` and thread `todoId`, so a newer alert replaces
///   the older one. See todo-app docs/superpowers/specs/2026-10-17-push-notifications-design.md.
@MainActor
@Observable
final class NotificationCenterCoordinator {
    static let shared = NotificationCenterCoordinator()

    /// Settings toggle "Notify me when a conversation needs me" (`@AppStorage` in Settings).
    static let enabledKey = "notify.needsYou"
    /// Mac only: also alert on this Mac when an iPhone receives pushes.
    static let macAlertsTooKey = "notify.macAlertsToo"
    private static let clientIdKey = "notify.clientId"
    /// Hub URL this device's push token is registered with (see `PushRegistrationState`).
    private static let registeredHubKey = "notify.registeredHub"
    static let category = "TODO_CONVERSATION"
    private static let muteAction = "MUTE_TODO"
    private static let presenceRefresh: Duration = .seconds(30)

    private(set) var pushState: PushState = .off

    /// Opens a todo's conversation. A tap that launched the app is replayed once this is set.
    var onOpenTodo: ((String) -> Void)? {
        didSet {
            if let todo = pendingOpenTodo, onOpenTodo != nil {
                pendingOpenTodo = nil
                open(todo)
            }
        }
    }

    private func open(_ todoId: String) {
        guard let onOpenTodo else {
            pendingOpenTodo = todoId
            return
        }
        NotificationCenter.default.post(name: .todoNotificationOpened, object: todoId)
        onOpenTodo(todoId)
    }

    @ObservationIgnored private var pendingOpenTodo: String?
    @ObservationIgnored fileprivate var presence = PresenceTracker()
    @ObservationIgnored private var registration = PushRegistrationState(
        registeredHub: UserDefaults.standard.string(forKey: registeredHubKey)
    )
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    @ObservationIgnored private var deviceToken: String?
    /// Mac: whether the server has a registered iPhone (refreshed when the app activates).
    @ObservationIgnored private var iPhoneRegisteredOnServer = false
    @ObservationIgnored private var installed = false
    @ObservationIgnored private let delegateProxy = DelegateProxy()

    private init() {}

    /// The conversation on screen while the app is active (`nil`: none, or the app is away).
    var visibleTodoId: String? { presence.visibleTodoId }

    private var hub: String { TodoHubSettings.baseURLString }

    private func saveRegistration() {
        UserDefaults.standard.set(registration.registeredHub, forKey: Self.registeredHubKey)
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private var clientId: String {
        if let id = UserDefaults.standard.string(forKey: Self.clientIdKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Self.clientIdKey)
        return id
    }

    /// Call once at launch, before the app finishes launching, so a tap that launched the
    /// app reaches the delegate.
    func install() {
        guard !installed else { return }
        installed = true
        let center = UNUserNotificationCenter.current()
        center.delegate = delegateProxy
        let mute = UNNotificationAction(identifier: Self.muteAction, title: "Mute this todo", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [mute], intentIdentifiers: [], options: []),
        ])
        let notifications = NotificationCenter.default
        notifications.addObserver(forName: Self.didBecomeActive, object: nil, queue: .main) { _ in
            Task { @MainActor in await NotificationCenterCoordinator.shared.didBecomeActive() }
        }
        notifications.addObserver(forName: PlatformSupport.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in NotificationCenterCoordinator.shared.didEnterBackground() }
        }
        notifications.addObserver(forName: .todoHubSettingsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in await NotificationCenterCoordinator.shared.uploadToken() }
        }
        #if os(macOS)
        // The Mac never enters the background: count switching to another app, sleeping
        // screens and a locked screen as "not looking", or a conversation left open would
        // suppress the iPhone's pushes for as long as the app runs.
        let away: [(NotificationCenter, Notification.Name)] = [
            (notifications, NSApplication.didResignActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
        ]
        for (center, name) in away {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in NotificationCenterCoordinator.shared.didEnterBackground() }
            }
        }
        let back: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in back {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    guard NSApplication.shared.isActive else { return }
                    NotificationCenterCoordinator.shared.applyPresence(NotificationCenterCoordinator.shared.presence.becomeActive())
                }
            }
        }
        #endif
        pushState = registration.launchState(enabled: isEnabled, hub: hub)
        if isEnabled {
            Task { await resume() }
        }
    }

    private static var didBecomeActive: Notification.Name {
        #if os(iOS)
        UIApplication.didBecomeActiveNotification
        #else
        NSApplication.didBecomeActiveNotification
        #endif
    }

    // MARK: Settings toggle

    /// Switches "needs you" notifications on (asks permission, registers for push) or off.
    /// Returns whether notifications are now on; the toggle reverts when it returns `false`.
    @discardableResult
    func setNeedsYouEnabled(_ on: Bool) async -> Bool {
        guard on else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            registration.disable()
            saveRegistration()
            pushState = .off
            if let token = deviceToken, let client = TodoHubSettings.makeClient() {
                try? await client.unregisterPushDevice(token: token)
            }
            #if os(iOS)
            UIApplication.shared.unregisterForRemoteNotifications()
            #endif
            deviceToken = nil
            return false
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            pushState = .off
            return false
        }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        await resume()
        return true
    }

    /// Notifications are on: register for push (iOS) or check for a registered iPhone (Mac).
    private func resume() async {
        #if os(iOS)
        pushState = registration.launchState(enabled: true, hub: hub)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        pushState = .localOnly("Alerts on this Mac while the app runs")
        await refreshServerDevices()
        #endif
    }

    // MARK: Remote push registration (called by AppDelegate)

    func didRegister(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        Task { await uploadToken() }
    }

    func didFailToRegister(_ error: Error) {
        pushState = .localOnly("Push registration failed: \(error.localizedDescription)")
    }

    /// Sends the token to the todo server. Runs on every launch, when the server settings
    /// change and (after a temporary failure) when the app becomes active; the server upserts.
    func uploadToken() async {
        guard isEnabled, let token = deviceToken else { return }
        guard let client = TodoHubSettings.makeClient() else {
            pushState = .localOnly("Set up the todo server to get push notifications")
            return
        }
        let hub = hub
        if registration.registeredHub != hub {
            pushState = .localOnly("Registering for push…")
        }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        #if os(iOS)
        let deviceName = UIDevice.current.name
        #else
        let deviceName = Host.current().localizedName
        #endif
        let registration = PushDeviceRegistration(
            token: token,
            platform: isMac ? .macos : .ios,
            environment: ApsEnvironment.current,
            bundleId: Bundle.main.bundleIdentifier ?? "com.aisessionremote.app",
            appVersion: version,
            deviceName: deviceName
        )
        let upload = self.registration.beginUpload(hub: hub)
        if let previous = upload.previousHub, let oldURL = TodoHubClient.baseURL(from: previous) {
            // The server changed: the old one would keep pushing. Best effort, with the
            // current token (it fails harmlessly when the old server used another one).
            try? await TodoHubClient(baseURL: oldURL, token: TodoHubSettings.token).unregisterPushDevice(token: token)
        }
        var failure: TodoHubError?
        do {
            _ = try await client.registerPushDevice(registration)
        } catch let error as TodoHubError {
            failure = error
        } catch {
            failure = .unreachable(error.localizedDescription)
        }
        switch self.registration.finishUpload(upload.id, hub: hub, error: failure, enabled: isEnabled) {
        case let .apply(state):
            pushState = state
        case .ignore:
            break
        case .unregisterAgain:
            // Switched off while this registration was in flight; it may have landed after the delete.
            try? await client.unregisterPushDevice(token: token)
        }
        saveRegistration()
    }

    private func refreshServerDevices() async {
        guard let client = TodoHubSettings.makeClient(), let status = try? await client.pushStatus() else { return }
        iPhoneRegisteredOnServer = status.configured && status.devices > 0
    }

    // MARK: Local alerts

    /// A conversation just turned `waiting`. Posts a local alert unless the server's push
    /// covers it or the conversation is on screen. `body` is "Needs you": never conversation text.
    func postWaiting(todoId: String, sessionId: String, title: String, body: String) {
        guard isEnabled,
              NotificationPolicy.shouldPostLocal(
                  pushState: pushState,
                  visibleTodoId: visibleTodoId,
                  todoId: todoId,
                  isMac: isMac,
                  iPhoneRegisteredOnServer: iPhoneRegisteredOnServer,
                  macAlertsToo: UserDefaults.standard.bool(forKey: Self.macAlertsTooKey)
              )
        else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = todoId
        content.categoryIdentifier = Self.category
        content.userInfo = ["todo_id": todoId, "session_id": sessionId, "kind": "waiting"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: NotificationPolicy.notificationIdentifier(todoId: todoId),
            content: content,
            trigger: nil
        ))
    }

    /// Host session list (plain SSH sessions, not todos): alert when a refresh finds sessions
    /// marked `waiting`. Independent of the todo toggle, as before it existed: posts whenever
    /// notifications are allowed (installs that granted permission at first launch keep these).
    func postSessionsWaiting(hostName: String, sessions: [RemoteSession]) {
        let waiting = sessions.filter { $0.status == .waiting }
        guard !waiting.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "Session needs attention"
        if waiting.count == 1, let only = waiting.first {
            content.body = "\(only.slug) on \(hostName)"
        } else {
            content.body = "\(waiting.count) sessions on \(hostName) are waiting"
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "waiting-\(hostName)-\(waiting.map(\.tmuxName).sorted().joined(separator: ","))",
            content: content,
            trigger: nil
        )
        Task {
            let center = UNUserNotificationCenter.current()
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional:
                try? await center.add(request)
            default:
                break
            }
        }
    }

    // MARK: Presence

    /// The conversation on screen (`nil`: none). Suppresses its alerts here and, through the
    /// server, its pushes on every device.
    func setVisibleConversation(todoId: String?) {
        applyPresence(presence.request(todoId))
    }

    private func didEnterBackground() {
        applyPresence(presence.enterBackground())
    }

    fileprivate func applyPresence(_ report: PresenceTracker.Report) {
        guard case let .report(todoId) = report else { return }
        presenceTask?.cancel()
        if let todoId {
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [NotificationPolicy.notificationIdentifier(todoId: todoId)]
            )
        }
        guard let client = TodoHubSettings.makeClient() else { return }
        let clientId = clientId
        guard let todoId else {
            reportCleared(client: client, clientId: clientId)
            return
        }
        presenceTask = Task {
            while !Task.isCancelled {
                try? await client.reportPresence(clientId: clientId, todoId: todoId)
                try? await Task.sleep(for: Self.presenceRefresh)
            }
        }
    }

    private func reportCleared(client: TodoHubClient, clientId: String) {
        #if os(iOS)
        // Runs as the app goes to the background; ask for the time to finish the request.
        let task = BackgroundTask()
        task.id = UIApplication.shared.beginBackgroundTask { task.end() }
        Task {
            try? await client.reportPresence(clientId: clientId, todoId: nil)
            task.end()
        }
        #else
        Task { try? await client.reportPresence(clientId: clientId, todoId: nil) }
        #endif
    }

    // MARK: Mute

    func setMuted(todoId: String, _ muted: Bool) async throws {
        guard let client = TodoHubSettings.makeClient() else { throw TodoHubError.invalidBaseURL }
        try await client.setTodoPushMuted(todoId: todoId, muted)
    }

    // MARK: App lifecycle

    /// Report the conversation still on screen again, retry a registration that failed for a
    /// temporary reason, remove alerts for conversations that no longer need the user, and
    /// (Mac) refresh whether an iPhone receives pushes.
    private func didBecomeActive() async {
        applyPresence(presence.becomeActive())
        guard isEnabled, let client = TodoHubSettings.makeClient() else { return }
        if registration.needsRetry {
            await uploadToken()
        }
        if isMac { await refreshServerDevices() }
        guard let conversations = try? await client.listConversations() else { return }
        let waiting = Set(conversations.filter { $0.status == .waiting }.map(\.todoId))
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().compactMap { PushPayload(userInfo: $0.request.content.userInfo) }
        center.removeDeliveredNotifications(
            withIdentifiers: NotificationPolicy.staleAlertIdentifiers(delivered: delivered, waitingTodoIds: waiting)
        )
    }

    // MARK: Delegate callbacks

    fileprivate func shouldPresent(_ payload: PushPayload?) -> Bool {
        guard let payload else { return true }
        return payload.todoId != visibleTodoId
    }

    fileprivate func handle(action: String, payload: PushPayload?) async {
        guard let payload else { return }
        switch action {
        case Self.muteAction:
            try? await setMuted(todoId: payload.todoId, true)
        case UNNotificationDefaultActionIdentifier:
            open(payload.todoId)
        default:
            break
        }
    }
}

/// `UNUserNotificationCenterDelegate` must be an `NSObject`; the coordinator is `@Observable`.
private final class DelegateProxy: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
        let show = await MainActor.run { NotificationCenterCoordinator.shared.shouldPresent(payload) }
        return show ? [.banner, .list, .sound] : []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let payload = PushPayload(userInfo: response.notification.request.content.userInfo)
        await NotificationCenterCoordinator.shared.handle(action: action, payload: payload)
    }
}

#if os(iOS)
/// A background task id that the expiration handler and the request both end, once.
private final class BackgroundTask: @unchecked Sendable {
    private let lock = NSLock()
    var id = UIBackgroundTaskIdentifier.invalid

    func end() {
        lock.lock()
        defer { lock.unlock() }
        guard id != .invalid else { return }
        let ending = id
        id = .invalid
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(ending) }
    }
}
#endif
