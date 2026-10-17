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
        // Three columns: sidebar, list and the conversation (the Main board is 1280×800).
        .defaultSize(width: 1280, height: 800)
        .commands {
            // Frees ⌘N for New Todo; New Session is ⌥⌘N on the sessions list's add button.
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Conversation") {
                PopOutButton(model: model)
                Divider()
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

        #if os(macOS)
        // ⧉ / ⇧⌘O: a conversation in its own window, keyed by todo id.
        WindowGroup(id: ConversationWindow.id, for: String.self) { $todoID in
            ConversationWindow(todoID: todoID)
                .environment(model)
        }
        .modelContainer(HostStore.shared)
        .defaultSize(width: 960, height: 640)

        // ⌘, and the sidebar's Settings row.
        Settings {
            SettingsView()
                .environment(model)
                .modelContainer(HostStore.shared)
        }
        #endif
    }
}

#if os(macOS)
/// Conversation ▸ Open in New Window (⇧⌘O) for the main window's selected conversation.
private struct PopOutButton: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open in New Window") {
            if let id = model.selectedTodoID { model.popOut(id, openWindow: openWindow) }
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(model.selectedTodoID == nil)
    }
}
#endif
