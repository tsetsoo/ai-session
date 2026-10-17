#if os(iOS)
import UIKit

/// The app's only `UIApplicationDelegate` (SwiftUI allows one adaptor): remote-push
/// registration callbacks, plus a scene delegate that forwards Home-screen quick actions to
/// `onShortcutItem`, so the rest of the app owns no delegate code.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Handles a Home-screen quick action; returns whether it was handled. A quick action
    /// that launched the app is replayed once this is set.
    @MainActor static var onShortcutItem: ((UIApplicationShortcutItem) -> Bool)? {
        didSet {
            if let onShortcutItem, let item = pendingShortcutItem {
                pendingShortcutItem = nil
                _ = onShortcutItem(item)
            }
        }
    }

    @MainActor private static var pendingShortcutItem: UIApplicationShortcutItem?

    @MainActor static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let onShortcutItem else {
            pendingShortcutItem = item
            return true
        }
        return onShortcutItem(item)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in NotificationCenterCoordinator.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in NotificationCenterCoordinator.shared.didFailToRegister(error) }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            Task { @MainActor in _ = AppDelegate.handle(item) }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = AppSceneDelegate.self
        return configuration
    }
}

/// Only forwards quick actions; SwiftUI's `WindowGroup` still owns the window.
final class AppSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in completionHandler(AppDelegate.handle(shortcutItem)) }
    }
}
#endif
