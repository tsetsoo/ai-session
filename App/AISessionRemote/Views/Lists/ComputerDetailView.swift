import AISessionCore
import SwiftData
import SwiftUI

/// One computer: its running conversations, then Other sessions, On this computer and Open
/// Shell. Without access on this device it offers Set Up Access instead.
struct ComputerDetailView: View {
    let computer: Computer
    /// Tapping a running conversation; rows aren't tappable without it.
    let onOpen: ((Todo) -> Void)?

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var actions = ConversationRowActions()
    @State private var setUpPrefill: HostEditorPrefill?

    init(computer: Computer, onOpen: ((Todo) -> Void)? = nil) {
        self.computer = computer
        self.onOpen = onOpen
    }

    private var store: TodoHubStore { model.store }

    var body: some View {
        let board = model.board
        let host = HostLookup.host(for: computer, in: hosts)
        let running = board.runningNow.filter { $0.computer.id == computer.id }
        let todos = Dictionary(store.todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        TimelineView(.everyMinute) { context in
            List {
                ListStatusBanner(store: store)
                if host == nil {
                    Section {
                        noAccess
                    }
                }
                Section {
                    if running.isEmpty {
                        Text("No conversations running. Open a todo to start one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(running, id: \.todoId) { conversation in
                        row(conversation, todo: todos[conversation.todoId], board: board, now: context.date)
                    }
                } header: {
                    Text("Running").textCase(nil)
                }
                if let host {
                    Section {
                        NavigationLink {
                            SessionsListView(host: host)
                        } label: {
                            Label("Other Sessions", systemImage: "terminal")
                        }
                        NavigationLink {
                            OnThisComputerView(computer: computer)
                        } label: {
                            Label("On This Computer", systemImage: "text.bubble")
                        }
                        NavigationLink {
                            ShellScreen(host: host)
                        } label: {
                            Label("Open Shell", systemImage: "apple.terminal")
                        }
                    } footer: {
                        Text("Other sessions run here without a todo. On This Computer lists conversations you can link to a todo or turn into a new one.")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(computer.name)
        .task { await model.refreshLiveness(hosts: hosts) }
        .refreshable {
            await store.refresh(trigger: .background)
            await model.refreshLiveness(hosts: hosts)
        }
        .conversationActions(actions, store: store, hosts: hosts)
        .sheet(item: $setUpPrefill) { prefill in
            // Create mode: the host and its key are saved together, and Cancel leaves nothing.
            HostEditorView(prefill: prefill)
        }
    }

    private var noAccess: some View {
        ContentUnavailableView {
            Label("This device can't open conversations on \(computer.name) yet",
                  systemImage: "desktopcomputer.trianglebadge.exclamationmark")
        } actions: {
            Button("Set Up Access") { setUpPrefill = HostEditorPrefill(computer: computer) }
                .buttonStyle(AccentButtonStyle())
        }
    }

    private func row(_ conversation: Conversation, todo: Todo?, board: ConversationBoard, now: Date) -> some View {
        let status = board.status(forTodo: conversation.todoId) ?? .closed
        let open: (() -> Void)? = todo.flatMap { todo in onOpen.map { onOpen in { onOpen(todo) } } }
        return ConversationRow(
            title: todo?.title ?? "Conversation",
            section: todo?.section,
            conversation: conversation,
            status: status,
            now: now,
            isBusy: actions.inFlight.contains(conversation.todoId)
        )
        .rowTap(open)
        .conversationRowMenu(conversation, isRunning: status != .closed, actions: actions,
                             store: store, hosts: hosts, open: open)
    }
}

/// A plain shell on the computer, outside tmux.
private struct ShellScreen: View {
    let host: HostEntity

    var body: some View {
        if let connection = try? SessionServiceFactory().make(for: host) {
            TerminalScreen(hostConfig: connection.config, mode: .plainShell, title: "Shell", onKill: {})
        } else {
            ContentUnavailableView(
                "Shell Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This device can't reach \(host.displayName) yet. Set up access in Settings.")
            )
        }
    }
}

#if DEBUG
#Preview("Computer") {
    NavigationStack {
        ComputerDetailView(computer: DemoFixtures.macStudio) { _ in }
    }
    .environment(AppModel(demo: true))
    .modelContainer(for: HostEntity.self, inMemory: true)
}
#endif
