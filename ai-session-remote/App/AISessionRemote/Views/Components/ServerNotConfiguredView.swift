import SwiftUI

/// No todo server yet: what to do, and Open Settings on the Server page (through the shell's
/// `openAppSettings`). Shared by both shells and the Projects list.
struct ServerNotConfiguredView: View {
    var systemImage = "checklist"
    var description = "Enter the server address and API token to see your todos."

    @Environment(\.openAppSettings) private var openAppSettings

    var body: some View {
        ContentUnavailableView {
            Label("Connect to your todo server", systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            if let openAppSettings {
                Button("Open Settings") { openAppSettings(.server) }
                    .buttonStyle(AccentButtonStyle())
            }
        }
    }
}
