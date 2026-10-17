import AISessionCore
import SwiftData
import SwiftUI

/// The conversation frame for a todo. A tap is an explicit open, so the loader starts (or
/// resumes) the conversation as soon as the frame appears. `attachOnly` (a notification tap)
/// only shows it: it attaches if the conversation runs and never starts or resumes one.
struct TodoConversationScreen: View {
    let todo: Todo
    let store: TodoHubStore
    let attachOnly: Bool
    let onDeleted: () -> Void

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var hostList: HostList
    @State private var loader: ConversationLoader
    /// The open (start, or attach for a notification tap) happens once per screen: coming back
    /// to it (another tab and back) after Close must not resume the conversation by itself.
    @State private var didOpen = false

    init(todo: Todo, store: TodoHubStore, attachOnly: Bool = false, onDeleted: @escaping () -> Void) {
        self.todo = todo
        self.store = store
        self.attachOnly = attachOnly
        self.onDeleted = onDeleted
        let hostList = HostList()
        _hostList = State(initialValue: hostList)
        var dependencies = ConversationLoader.Dependencies.live(store: store, hosts: { hostList.hosts })
        #if DEBUG
        if DemoFixtures.isEnabled { dependencies = DemoFixtures.loaderDependencies() }
        #endif
        _loader = State(initialValue: ConversationLoader(todo: todo, dependencies: dependencies))
    }

    var body: some View {
        frame
            .onChange(of: hosts) { _, hosts in hostList.hosts = hosts }
            .task {
                hostList.hosts = hosts
                guard !didOpen, loader.phase == .idle else { return }
                didOpen = true
                if attachOnly {
                    // Running as far as the board knows (hub status and listed tmux sessions);
                    // a stale alert must not recreate a dead session.
                    let running = model.board.status(forTodo: todo.id).map { $0 != .closed } ?? false
                    await loader.attachIfRunning(running ? store.conversations[todo.id] : nil)
                } else {
                    await loader.start()
                }
            }
    }

    private var frame: ConversationFrame {
        #if DEBUG
        if DemoFixtures.isEnabled {
            return ConversationFrame(todo: todo, loader: loader, store: store, onDeleted: onDeleted,
                                     makeTransport: { _, _ in DemoTransport() })
        }
        #endif
        return ConversationFrame(todo: todo, loader: loader, store: store, onDeleted: onDeleted)
    }
}

/// The current saved hosts, read by the loader on every resolve (a host added from the frame's
/// Set Up Access then counts on retry).
@MainActor
private final class HostList {
    var hosts: [HostEntity] = []
}
