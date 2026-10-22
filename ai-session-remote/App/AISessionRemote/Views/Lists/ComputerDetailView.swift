import AISessionCore
import SwiftData
import SwiftUI

/// A computer's tools besides its conversations. In the Mac shell they open in the detail
/// column: their rows select like conversations, tagged `page:<name>`.
enum ComputerPage: String, CaseIterable {
    case otherSessions, onThisComputer, shell

    var tag: String { "page:\(rawValue)" }

    init?(tag: String?) {
        guard let tag, tag.hasPrefix("page:") else { return nil }
        self.init(rawValue: String(tag.dropFirst("page:".count)))
    }

    var title: String {
        switch self {
        case .otherSessions: "Other Sessions"
        case .onThisComputer: "On This Computer"
        case .shell: "Open Shell"
        }
    }

    var systemImage: String {
        switch self {
        case .otherSessions: "terminal"
        case .onThisComputer: "text.bubble"
        case .shell: "apple.terminal"
        }
    }

    @MainActor @ViewBuilder
    func destination(computer: Computer, host: HostEntity) -> some View {
        switch self {
        case .otherSessions: SessionsListView(host: host)
        case .onThisComputer: OnThisComputerView(computer: computer)
        case .shell: ShellScreen(host: host)
        }
    }
}

/// One computer: its running conversations, then Other sessions, On this computer and Open
/// Shell. Without access on this device it offers Set Up Access instead. Given a `selection`
/// (the Mac list column) running conversations select by todo id instead of being tapped, and
/// the pages select by `ComputerPage.tag` for the shell to show in its detail column.
struct ComputerDetailView: View {
    let computer: Computer
    /// Tapping a running conversation; rows aren't tappable without it.
    let onOpen: ((Todo) -> Void)?
    private let query: String
    private let selection: Binding<String?>?

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var actions = ConversationRowActions()
    @State private var setUpPrefill: HostEditorPrefill?

    init(computer: Computer, query: String = "", selection: Binding<String?>? = nil,
         onOpen: ((Todo) -> Void)? = nil) {
        self.computer = computer
        self.query = query
        self.selection = selection
        self.onOpen = onOpen
    }

    private var store: TodoHubStore { model.store }

    var body: some View {
        let board = model.board
        let host = HostLookup.host(for: computer, in: hosts)
        let todos = Dictionary(store.todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let running = board.open.filter { conversation in
            let todo = todos[conversation.todoId]
            return conversation.computer.id == computer.id
                && ListSearch.matches(query, todo?.title,
                                      RowText.conversationSearchText(conversation, section: todo?.section),
                                      conversation.statusMessage)
        }
        SelectableList(selection: selection) {
            ListStatusBanner(store: store)
            if host == nil {
                Section {
                    noAccess
                }
            }
            Section {
                if running.isEmpty && !query.isEmpty {
                    Text("No results for “\(query)”")
                        .foregroundStyle(.secondary)
                } else if running.isEmpty {
                    Text("No open conversations. Open a todo to start one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(running, id: \.listKey) { conversation in
                    row(conversation, todo: todos[conversation.todoId], board: board)
                }
            } header: {
                Text("Open").textCase(nil)
            }
            if let host {
                Section {
                    ForEach(ComputerPage.allCases, id: \.self) { page in
                        if selection != nil {
                            Label(page.title, systemImage: page.systemImage)
                                .tag(page.tag)
                        } else {
                            NavigationLink {
                                page.destination(computer: computer, host: host)
                            } label: {
                                Label(page.title, systemImage: page.systemImage)
                            }
                        }
                    }
                } footer: {
                    Text("Other sessions run here without a todo. On This Computer lists conversations you can link to a todo or turn into a new one.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(computer.name)
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

    @ViewBuilder
    private var noAccess: some View {
        if selection != nil {
            // The Mac's narrow list column: a row, not a full-screen title.
            VStack(alignment: .leading, spacing: DS.spacing.s) {
                Label {
                    Text("This device can't open conversations on \(computer.name) yet")
                } icon: {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color.secondary)
                }
                .font(.headline)
                Button("Set Up Access") { setUpPrefill = HostEditorPrefill(computer: computer) }
                    .buttonStyle(AccentButtonStyle())
            }
            .padding(.vertical, DS.spacing.s)
        } else {
            fullNoAccess
        }
    }

    private var fullNoAccess: some View {
        ContentUnavailableView {
            Label("This device can't open conversations on \(computer.name) yet",
                  systemImage: "desktopcomputer.trianglebadge.exclamationmark")
        } actions: {
            Button("Set Up Access") { setUpPrefill = HostEditorPrefill(computer: computer) }
                .buttonStyle(AccentButtonStyle())
        }
    }

    private func row(_ conversation: Conversation, todo: Todo?, board: ConversationBoard) -> some View {
        let status = board.status(of: conversation)
        let open: (() -> Void)? = todo.flatMap { todo in
            onOpen.map { onOpen in
                {
                    model.selectedConversationID = conversation.listKey
                    onOpen(todo)
                }
            }
        }
        return ConversationRow(
            title: RowText.conversationTitle(todoTitle: todo?.title ?? "Conversation", label: conversation.label),
            section: todo?.section,
            conversation: conversation,
            status: status,
            isBusy: actions.inFlight.contains(conversation.listKey),
            onDone: todo.flatMap { todo in
                todo.completed || store.isOffline ? nil : { Task { await store.toggle(todo) } }
            }
        )
        .tag(conversation.listKey)
        .rowTap(selection == nil ? open : nil)
        .conversationRowMenu(conversation, todo: todo, isRunning: status != .closed, actions: actions,
                             store: store, hosts: hosts, open: open)
    }
}

/// A plain shell on the computer, outside tmux.
struct ShellScreen: View {
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
