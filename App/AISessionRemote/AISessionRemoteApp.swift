import SwiftData
import SwiftUI

@main
struct AISessionRemoteApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        // `--hub-url …` / `--add-host …` set the app up from launch arguments
        // (see HostProvisioning). On the Mac the app exits afterwards.
        HostProvisioning.runFromCommandLineIfRequested()
        #if os(macOS)
        TextSizeShortcuts.installBiggerTextAliasMonitor()
        #endif
        // Before launch finishes, so a notification tap that launched the app is delivered.
        NotificationCenterCoordinator.shared.install()
        // `--notify-on` asks for notification permission and registers this device, so the
        // phone can be set up from a launch argument the same way `--hub-url` sets the server.
        if ProcessInfo.processInfo.arguments.contains("--notify-on") {
            Task { _ = await NotificationCenterCoordinator.shared.setNeedsYouEnabled(true) }
        }
    }

    @State private var model = AppModel()
    @AppStorage("terminal.fontSize") private var terminalFontSize = TerminalAppearance.defaultFontSize

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Notification permission is asked only from Settings → Notifications.
                .onAppear { model.installSystemEntryPoints() }
                .onReceive(NotificationCenter.default.publisher(
                    for: PlatformSupport.didEnterBackgroundNotification
                )) { _ in
                    // iOS suspends sockets while backgrounded; a half-dead socket costs a full
                    // connect timeout on the next use, so closing eagerly here is faster than
                    // discovering deadness later.
                    //
                    // Deliberately NOT mirrored on `didBecomeActiveNotification`. That
                    // notification also fires after a merely transient `willResignActive` that
                    // never actually backgrounded the app — Control Center, Notification Center,
                    // an incoming-call banner, a share sheet, a permission prompt — and closing
                    // there would tear down a perfectly healthy connection out from under any
                    // command still in flight. After a genuine background/foreground cycle this
                    // handler has already emptied the pool, so a foreground close would only ever
                    // be a no-op (or, on a false alarm, actively harmful) — it buys nothing this
                    // handler doesn't already provide. Do not add it back.
                    Task { await NIOSSHClient.shared.closeAll() }
                }
        }
        .modelContainer(HostStore.shared)
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        .commands {
            // Frees ⌘N for "New Session" (bound on the sessions list's add button).
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Conversation") {
                // Plain ⌘= is handled by a key monitor (TextSizeShortcuts), since ⌘+ needs Shift.
                Button("Bigger Text") { TextSizeShortcuts.step(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { TextSizeShortcuts.step(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                Button("Default Text Size") {
                    terminalFontSize = TerminalAppearance.defaultFontSize
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }
        #endif
    }
}
