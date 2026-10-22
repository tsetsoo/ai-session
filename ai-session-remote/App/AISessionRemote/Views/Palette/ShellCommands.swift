import SwiftUI

/// The fast paths a `MacShell` offers its scene's menu commands: ⌘K, ⌘1–⌘9 and ⌘N.
///
/// Published per scene (`focusedSceneValue`), so the commands act on the key window's shell.
/// A pop-out conversation window or the Settings window has no shell: there they are disabled.
/// So is a shell showing one of its sheets.
struct ShellCommands {
    /// ⌘K.
    let goTo: () -> Void
    /// The menu titles of ⌘1–⌘9: the conversation list on screen, at most nine. Empty outside
    /// the conversation lists, where no numbers are drawn.
    let conversationTitles: [String]
    /// ⌘n (1-based).
    let openConversation: (Int) -> Void
    /// ⌘N; `nil` while new todos can't be added (offline, no server).
    let newTodo: (() -> Void)?
}

/// ⌘⏎ and ⌘⌫ for the todo selected in the list column. Published with `focusedValue` from
/// the list, so only while it has keyboard focus: in the search field or a terminal those
/// keys keep their text-editing meaning.
struct SelectedTodoCommands {
    let isDone: Bool
    let toggleDone: () -> Void
    /// Asks first (`todoDeleteConfirmation`).
    let delete: () -> Void
}

extension FocusedValues {
    @Entry var shellCommands: ShellCommands?
    @Entry var selectedTodoCommands: SelectedTodoCommands?
}

/// Conversation ▸ Go to… (⌘K), New Todo (⌘N), the selected todo's Mark as Done (⌘⏎) and
/// Delete Todo… (⌘⌫), and the conversations of the list on screen (⌘1–⌘9), for the key
/// window's shell.
struct ShellCommandItems: View {
    @FocusedValue(\.shellCommands) private var shell
    @FocusedValue(\.selectedTodoCommands) private var selectedTodo

    var body: some View {
        Button("Go to…") { shell?.goTo() }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(shell == nil)
        Button("New Todo") { shell?.newTodo?() }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(shell?.newTodo == nil)
        Divider()
        Button(selectedTodo?.isDone == true ? "Mark as Not Done" : "Mark as Done") { selectedTodo?.toggleDone() }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(selectedTodo == nil)
        Button("Delete Todo…") { selectedTodo?.delete() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selectedTodo == nil)
        Divider()
        let titles = shell?.conversationTitles ?? []
        ForEach(1...9, id: \.self) { n in
            Button(n <= titles.count ? titles[n - 1] : "Conversation \(n)") { shell?.openConversation(n) }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                .disabled(n > titles.count)
        }
    }
}
