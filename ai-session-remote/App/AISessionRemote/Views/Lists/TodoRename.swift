import AISessionCore
import SwiftUI

/// Renaming a todo: the hub's title first, then each of its Claude / Codex conversations on
/// their computers, so the tool's own session list shows the same name.
@MainActor
enum TodoRename {
    /// The title to save, or nil while Rename should stay off (blank or unchanged).
    /// Whitespace collapses, as the host script does with a conversation's name.
    static func title(from text: String, current: String) -> String? {
        let title = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty, title != current else { return nil }
        return title
    }

    /// Todos whose rename is still running, on any screen. Another rename of the same todo is
    /// ignored until it finishes, so its computers can't end up with different names.
    static var inFlight: Set<String> = []

    /// What the dialog says about the todo's conversations, or nil when it has none to rename.
    static func dialogMessage(renamableCount: Int) -> String? {
        switch renamableCount {
        case 0: nil
        case 1: "Its conversation gets the same name."
        default: "Its \(renamableCount) conversations get the same name."
        }
    }

    /// The todo was renamed but a conversation on `computer` kept its old name.
    static func conversationFailureMessage(_ error: Error, computer: Computer) -> String {
        "The todo has its new name, but its conversation on \(computer.name) kept the old one. "
            + ConversationRowActions.message(for: error, computer: computer)
    }
}

extension View {
    /// The Rename Todo dialog for `target`, and its failure alert. Set the binding to ask.
    func todoRename(_ target: Binding<Todo?>, store: TodoHubStore, hosts: [HostEntity]) -> some View {
        modifier(TodoRenamePresenter(target: target, store: store, hosts: hosts))
    }
}

/// "Rename…" for a todo's menus. Left out offline, like the other changing items.
struct RenameTodoButton: View {
    let todo: Todo
    let store: TodoHubStore
    let rename: (Todo) -> Void

    var body: some View {
        if !store.isOffline {
            Button {
                rename(todo)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        }
    }
}

private struct TodoRenamePresenter: ViewModifier {
    @Binding var target: Todo?
    let store: TodoHubStore
    let hosts: [HostEntity]

    @State private var text = ""
    @State private var failure: ConversationRowActions.Failure?
    @State private var setUpPrefill: HostEditorPrefill?

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename Todo",
                isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                presenting: target
            ) { todo in
                TextField("Title", text: $text)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { save(todo) }
                    .disabled(TodoRename.title(from: text, current: todo.title) == nil)
            } message: { todo in
                if let message = TodoRename.dialogMessage(
                    renamableCount: RemoteConversations.renamable(store.conversations(forTodo: todo.id)).count
                ) {
                    Text(message)
                }
            }
            .onChange(of: target?.id) {
                if let target { text = target.title }
            }
            .alert(
                failure?.title ?? "",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                presenting: failure
            ) { failure in
                if let computer = failure.setUpAccess {
                    Button("Set Up Access") { setUpPrefill = HostEditorPrefill(computer: computer) }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { failure in
                Text(failure.message)
            }
            .sheet(item: $setUpPrefill) { prefill in
                HostEditorView(prefill: prefill)
            }
    }

    private func save(_ todo: Todo) {
        guard let title = TodoRename.title(from: text, current: todo.title),
              !TodoRename.inFlight.contains(todo.id) else { return }
        TodoRename.inFlight.insert(todo.id)
        // Looked up now, on the main actor: host entities stay here.
        let jobs = RemoteConversations.renamable(store.conversations(forTodo: todo.id)).map { conversation in
            (conversation, Result { try HostLookup.config(for: conversation.computer, in: hosts) })
        }
        let store = store
        Task {
            defer { TodoRename.inFlight.remove(todo.id) }
            do {
                try await store.rename(todo, to: title)
            } catch {
                failure = .init(title: "Couldn't Rename Todo", message: TodoHubStore.message(for: error))
                return
            }
            // Every computer at once: one that's asleep doesn't hold up the others.
            let failures = await withTaskGroup(of: (Computer, Error)?.self) { group in
                for (conversation, config) in jobs {
                    group.addTask {
                        do {
                            try await store.renameConversation(conversation, to: title, config: config.get())
                            return nil
                        } catch {
                            return (conversation.computer, error)
                        }
                    }
                }
                var failures: [(Computer, Error)] = []
                for await failure in group {
                    if let failure { failures.append(failure) }
                }
                return failures
            }
            // The first one is reported.
            if let (computer, error) = failures.first {
                failure = .init(
                    title: "Conversation Not Renamed",
                    message: TodoRename.conversationFailureMessage(error, computer: computer),
                    setUpAccess: ConversationRowActions.computerToSetUp(after: error)
                )
            }
        }
    }
}
