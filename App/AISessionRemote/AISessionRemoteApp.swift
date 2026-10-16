import SwiftData
import SwiftUI

@main
struct AISessionRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            HostsListView()
                .onAppear { AttentionNotifier.requestAuthorizationIfNeeded() }
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
        .modelContainer(for: HostEntity.self)
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        .commands {
            // Frees ⌘N for "New Session" (bound on the sessions list's add button).
            CommandGroup(replacing: .newItem) {}
        }
        #endif
    }
}
