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
                if !RemoteConversations.renamable(store.conversations(forTodo: todo.id)).isEmpty {
                    Text("Its conversation gets the same name.")
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
        guard let title = TodoRename.title(from: text, current: todo.title) else { return }
        let conversations = RemoteConversations.renamable(store.conversations(forTodo: todo.id))
        Task {
            do {
                try await store.rename(todo, to: title)
            } catch {
                failure = .init(title: "Couldn't Rename Todo", message: TodoHubStore.message(for: error))
                return
            }
            // One computer's failure doesn't stop the others; the first one is reported.
            var firstFailure: ConversationRowActions.Failure?
            for conversation in conversations {
                do {
                    let config = try HostLookup.config(for: conversation.computer, in: hosts)
                    try await store.renameConversation(conversation, to: title, config: config)
                } catch {
                    firstFailure = firstFailure ?? .init(
                        title: "Conversation Not Renamed",
                        message: TodoRename.conversationFailureMessage(error, computer: conversation.computer),
                        setUpAccess: ConversationRowActions.computerToSetUp(after: error)
                    )
                }
            }
            failure = firstFailure
        }
    }
}
