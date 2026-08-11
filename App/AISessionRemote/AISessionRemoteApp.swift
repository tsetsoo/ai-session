import SwiftData
import SwiftUI

@main
struct AISessionRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            HostsListView()
                .onAppear { AttentionNotifier.requestAuthorizationIfNeeded() }
        }
        .modelContainer(for: HostEntity.self)
    }
}
