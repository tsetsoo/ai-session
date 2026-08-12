import SwiftData
import SwiftUI
import UIKit

@main
struct AISessionRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            HostsListView()
                .onAppear { AttentionNotifier.requestAuthorizationIfNeeded() }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didEnterBackgroundNotification
                )) { _ in
                    // iOS suspends sockets while backgrounded; a half-dead socket costs a full
                    // connect timeout on the next use, so closing eagerly here is faster than
                    // discovering deadness later.
                    Task { await NIOSSHClient.shared.closeAll() }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didBecomeActiveNotification
                )) { _ in
                    // Close on resume too, so the next action dials fresh rather than slowly
                    // discovering a connection that went stale while backgrounded.
                    Task { await NIOSSHClient.shared.closeAll() }
                }
        }
        .modelContainer(for: HostEntity.self)
    }
}
