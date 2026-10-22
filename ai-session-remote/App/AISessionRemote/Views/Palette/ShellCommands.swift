import SwiftUI

/// The fast paths a `MacShell` offers its scene's menu commands: ⌘K, ⌘1–⌘9 and ⌘N.
///
/// Published per scene (`focusedSceneValue`), so the commands act on the key window's shell.
/// A pop-out conversation window or the Settings window has no shell: there they are disabled.
/// So is a shell showing one of its sheets.
struct ShellCommands {
    /// ⌘K.
    let goTo: () -> Void
    /// How many of ⌘1–⌘9 have a conversation in the list on screen.
    let conversationCount: Int
    /// ⌘n (1-based).
    let openConversation: (Int) -> Void
    /// ⌘N; `nil` while new todos can't be added (offline, no server).
    let newTodo: (() -> Void)?
}

extension FocusedValues {
    @Entry var shellCommands: ShellCommands?
}

/// Conversation ▸ Go to… (⌘K), New Todo (⌘N) and Conversation 1…9 (⌘1–⌘9), for the key
/// window's shell.
struct ShellCommandItems: View {
    @FocusedValue(\.shellCommands) private var shell

    var body: some View {
        Button("Go to…") { shell?.goTo() }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(shell == nil)
        Button("New Todo") { shell?.newTodo?() }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(shell?.newTodo == nil)
        Divider()
        ForEach(1...9, id: \.self) { n in
            Button("Conversation \(n)") { shell?.openConversation(n) }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                .disabled(n > (shell?.conversationCount ?? 0))
        }
    }
}
