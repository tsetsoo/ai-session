import AISessionCore
import SwiftData
import SwiftUI

/// The conversation frame for a todo.
///
/// - `.start`: a tap on iPhone is an explicit open, so the loader starts (or resumes) the
///   conversation as soon as the frame appears.
/// - `.attachIfRunning`: a selection on the Mac never starts anything. It attaches only to a
///   conversation the board shows running, and otherwise shows Start / Resume.
struct TodoConversationScreen: View {
    enum OnAppear {
        case start, attachIfRunning
    }

    let todo: Todo
    let store: TodoHubStore
    let onAppear: OnAppear
    let onDeleted: () -> Void

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var hostList: HostList
    @State private var loader: ConversationLoader

    init(todo: Todo, store: TodoHubStore, onAppear: OnAppear = .start, onDeleted: @escaping () -> Void) {
        self.todo = todo
        self.store = store
        self.onAppear = onAppear
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
                guard loader.phase == .idle else { return }
                switch onAppear {
                case .start:
                    await loader.start()
                case .attachIfRunning:
                    // A conversation whose tmux session is gone shows as closed: attaching would
                    // start it again, so leave it to Resume.
                    guard let status = model.board.status(forTodo: todo.id), status != .closed else { return }
                    await loader.attachIfRunning(store.conversations[todo.id])
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
