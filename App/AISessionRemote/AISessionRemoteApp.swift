import SwiftData
import SwiftUI

@main
struct AISessionRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            HostsListView()
        }
        .modelContainer(for: HostEntity.self)
    }
}
