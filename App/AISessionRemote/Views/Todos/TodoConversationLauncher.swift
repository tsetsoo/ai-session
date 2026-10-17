import AISessionCore
import SwiftUI

/// Shared by the Todos list and project pages. Opening a todo's conversation itself goes
/// through `TodoConversationScreen` (a `ConversationFrame` driven by a `ConversationLoader`),
/// which does the hub get-or-create and the host lookup.
@MainActor
enum TodoConversationLauncher {
    static func newHostPrefill(for computer: Computer) -> HostEditorPrefill {
        HostEditorPrefill(
            displayName: computer.name,
            hostname: computer.hostname,
            port: computer.port,
            username: computer.username
        )
    }
}
