import AISessionCore
import SwiftData
import SwiftUI

/// A computer's tools besides its conversations. In the Mac shell they open in the detail
/// column: their rows select like conversations, tagged `page:<name>`.
enum ComputerPage: String, CaseIterable {
    case otherSessions, onThisComputer, health, shell

    var tag: String { "page:\(rawValue)" }

    init?(tag: String?) {
        guard let tag, tag.hasPrefix("page:") else { return nil }
        self.init(rawValue: String(tag.dropFirst("page:".count)))
    }

    var title: String {
        switch self {
        case .otherSessions: "Other Sessions"
        case .onThisComputer: "On This Computer"
        case .health: "Health"
        case .shell: "Open Shell"
        }
    }

    var systemImage: String {
        switch self {
        case .otherSessions: "terminal"
        case .onThisComputer: "text.bubble"
        case .health: "stethoscope"
        case .shell: "apple.terminal"
        }
    }

    @MainActor @ViewBuilder
    func destination(computer: Computer, host: HostEntity) -> some View {
        switch self {
        case .otherSessions: SessionsListView(host: host)
        case .onThisComputer: OnThisComputerView(computer: computer)
        case .health: ComputerHealthView(computer: computer)
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

    /// This computer's global memories (no project) that an agent proposed.
    @State private var pendingGlobal: [Memory] = []

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
        #if os(macOS)
        let active = running.filter { !board.isOnHold($0) }
        let held = running.filter { board.isOnHold($0) }
        #else
        let active = running
        #endif
        SelectableList(selection: selection) {
            ListStatusBanner(store: store)
            if host == nil {
                Section {
                    noAccess
                }
            }
            PendingMemoriesSection(memories: pendingGlobal, store: store)
            Section {
                if running.isEmpty && !query.isEmpty {
                    Text("No results for “\(query)”")
                        .foregroundStyle(.secondary)
                } else if running.isEmpty {
                    Text("No open conversations. Open a todo to start one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(active, id: \.listKey) { conversation in
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
                    Text("Manage other sessions, link conversations to todos, check the computer's health, or open a shell that keeps running when you leave.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            #if os(macOS)
            Section {
                TodoHoldDropArea(store: store)
                ForEach(held, id: \.listKey) { conversation in
                    row(conversation, todo: todos[conversation.todoId], board: board)
                }
            } header: {
                Text("On hold (\(held.count))").textCase(nil)
                    .todoHoldDropTarget(store: store)
            }
            #endif
        }
        .listStyle(.insetGrouped)
        .task(id: "\(computer.id)|\(store.revision)") {
            pendingGlobal = (try? await store.pendingMemories(computerId: computer.id)) ?? []
        }
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
        .todoDragSource(todo, store: store)
        .todoHoldDropTarget(store: store, enabled: todo?.onHold == true)
    }
}

/// On compact screens, returning to Open Shell reattaches the saved shell and offers more.
struct ShellScreen: View {
    let host: HostEntity
    @Environment(AppModel.self) private var model
    @State private var selectedID: UUID?

    private var shells: [WorkspaceShell] { model.shells.shells.filter { $0.hostID == host.id } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Shell", selection: $selectedID) {
                    ForEach(shells) { shell in Text(shell.title).tag(Optional(shell.id)) }
                }
                Button("New Shell", systemImage: "plus") { create() }
            }
            .padding()
            if let shell = shells.first(where: { $0.id == selectedID }) {
                PersistentShellTerminal(shell: shell, host: host)
                    .id(shell.id)
            }
        }
        .onAppear {
            if shells.isEmpty {
                create()
            } else {
                selectedID = model.shells.selection(for: host.id, current: selectedID)
            }
        }
        .onChange(of: selectedID) { _, id in model.shells.rememberSelection(id, for: host.id) }
        .onChange(of: shells.map(\.id)) { _, _ in
            selectedID = model.shells.selection(for: host.id, current: selectedID)
        }
    }

    private func create() {
        selectedID = model.shells.create(hostID: host.id, computerName: host.displayName).id
    }
}

struct PersistentShellTerminal: View {
    let shell: WorkspaceShell
    let host: HostEntity
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let connection = try? SessionServiceFactory().make(for: host) {
            TerminalScreen(
                hostConfig: connection.config,
                mode: .attach(TmuxCommandBuilder.persistentShell(tmuxName: shell.tmuxName)),
                title: shell.label,
                onKill: {
                    try await connection.service.killSession(config: connection.config, tmuxName: shell.tmuxName)
                    model.shells.forget(shell)
                },
                onDetach: {
                    model.shells.selectedID = nil
                    dismiss()
                }
            )
        } else {
            ContentUnavailableView(
                "Shell Unavailable", systemImage: "exclamationmark.triangle",
                description: Text("Set up access to \(shell.computerName) in Settings.")
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
