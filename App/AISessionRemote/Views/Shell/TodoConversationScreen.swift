import AISessionCore
import SwiftData
import SwiftUI

/// The conversation frame for a tapped todo. A tap is an explicit open, so the loader starts
/// (or resumes) the conversation as soon as the frame appears.
struct TodoConversationScreen: View {
    let todo: Todo
    let store: TodoHubStore
    let onDeleted: () -> Void

    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var hostList: HostList
    @State private var loader: ConversationLoader

    init(todo: Todo, store: TodoHubStore, onDeleted: @escaping () -> Void) {
        self.todo = todo
        self.store = store
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
                await loader.start()
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
