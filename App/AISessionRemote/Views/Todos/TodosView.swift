import AISessionCore
import SwiftData
import SwiftUI

/// A todo's conversation opened on a known SSH host; drives navigation to the terminal.
struct OpenTodoConversation: Identifiable, Hashable {
    let conversation: Conversation
    let hostID: UUID
    let title: String

    var id: String { conversation.todoId }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.hostID == rhs.hostID }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Todos grouped by section (Sp / I / Si / P). Tapping a todo opens its AI conversation on the
/// section's computer over a direct SSH connection; the hub only stores the mapping.
struct TodosView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var store = TodoHubStore()
    @State private var showingSettings = false
    @State private var showingComputers = false
    @State private var showingAdd = false
    @State private var openConversation: OpenTodoConversation?
    @State private var openingTodoID: String?
    @State private var missingHost: Computer?
    @State private var hostToEdit: HostEntity?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Todos")
                .toolbar { toolbar }
                .refreshable { await store.refresh() }
                .navigationDestination(item: $openConversation) { open in
                    conversationDestination(open)
                }
        }
        .sheet(isPresented: $showingSettings) {
            TodoHubSettingsView { Task { await store.reconnect() } }
        }
        .sheet(isPresented: $showingComputers) {
            ComputersView(store: store)
        }
        .sheet(isPresented: $showingAdd) {
            AddTodoSheet { section, title in
                Task { await store.createTodo(section: section, title: title) }
            }
        }
        .sheet(item: $hostToEdit) { host in
            HostEditorView(host: host)
        }
        .alert(
            "No SSH host for this computer",
            isPresented: Binding(get: { missingHost != nil }, set: { if !$0 { missingHost = nil } }),
            presenting: missingHost
        ) { computer in
            Button("Add Host") { addHost(for: computer) }
            Button("Cancel", role: .cancel) {}
        } message: { computer in
            Text("Add \(computer.username)@\(computer.hostname):\(computer.port) as a host and import its SSH key, then open the todo again.")
        }
        .alert(
            "Todos",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .task {
            guard store.isConfigured else { return }
            await store.refresh()
            store.startLiveUpdates()
        }
    }

    @ViewBuilder
    private var content: some View {
        if !store.isConfigured {
            ContentUnavailableView {
                Label("Connect to your todo server", systemImage: "checklist")
            } description: {
                Text("Enter the server URL and API token to see your todos.")
            } actions: {
                Button("Set Up") { showingSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if store.todos.isEmpty && !store.hasLoadedOnce {
            ProgressView()
        } else {
            List {
                if store.isOffline {
                    offlineBanner
                }
                ForEach(TodoSection.allCases) { section in
                    sectionView(section)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var offlineBanner: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline — read only").font(.subheadline.weight(.semibold))
                if let cachedAt = store.cachedAt, let ago = AppTheme.relativeTime(from: cachedAt) {
                    Text("Showing todos from \(ago)").font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "wifi.slash").foregroundStyle(.orange)
        }
    }

    private func sectionView(_ section: TodoSection) -> some View {
        Section {
            let todos = store.todos(in: section)
            if todos.isEmpty {
                Text("No todos").foregroundStyle(.secondary)
            }
            ForEach(todos) { todo in
                TodoRow(
                    todo: todo,
                    status: store.conversations[todo.id]?.status ?? todo.conversationStatus,
                    isOpening: openingTodoID == todo.id,
                    onToggle: { Task { await store.toggle(todo) } }
                )
                .contentShape(Rectangle())
                .onTapGesture { open(todo) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await store.delete(todo) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(store.isOffline)
                }
            }
        } header: {
            HStack {
                Text(section.rawValue).font(.headline)
                Spacer()
                if let mapping = store.sectionComputers[section] {
                    Label(mapping.computer.name, systemImage: "desktopcomputer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button {
                    showingComputers = true
                } label: {
                    Label("Computers", systemImage: "desktopcomputer")
                }
                .disabled(!store.isConfigured)
                Button {
                    showingSettings = true
                } label: {
                    Label("Server", systemImage: "server.rack")
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAdd = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Todo")
            .disabled(!store.isConfigured || store.isOffline)
        }
    }

    // MARK: Conversations

    private func open(_ todo: Todo) {
        guard openingTodoID == nil else { return }
        openingTodoID = todo.id
        Task {
            defer { openingTodoID = nil }
            let conversation: Conversation
            if store.isOffline, let cached = store.conversations[todo.id], cached.status != .closed {
                // The hub is down but the computer may not be: attach with what we know.
                conversation = cached
            } else {
                do {
                    conversation = try await store.openConversation(for: todo)
                } catch TodoHubError.conflict {
                    store.errorMessage = "Section \(todo.section.rawValue) has no computer assigned. Assign one under Settings → Computers."
                    return
                } catch {
                    store.errorMessage = TodoHubStore.message(for: error)
                    return
                }
            }
            guard let host = matchingHost(for: conversation.computer) else {
                missingHost = conversation.computer
                return
            }
            openConversation = OpenTodoConversation(conversation: conversation, hostID: host.id, title: todo.title)
        }
    }

    private func matchingHost(for computer: Computer) -> HostEntity? {
        hosts.first {
            $0.hostname.caseInsensitiveCompare(computer.hostname) == .orderedSame
                && $0.port == computer.port
                && $0.username == computer.username
        }
    }

    private func addHost(for computer: Computer) {
        let host = HostEntity(
            displayName: computer.name,
            hostname: computer.hostname,
            port: computer.port,
            username: computer.username
        )
        modelContext.insert(host)
        try? modelContext.save()
        hostToEdit = host
    }

    @ViewBuilder
    private func conversationDestination(_ open: OpenTodoConversation) -> some View {
        if let host = hosts.first(where: { $0.id == open.hostID }),
           let connection = try? SessionServiceFactory().make(for: host) {
            let conversation = open.conversation
            TerminalScreen(
                hostConfig: connection.config,
                mode: .attach(TmuxCommandBuilder.openTodoConversation(
                    tmuxName: conversation.tmuxName,
                    cwd: conversation.cwd,
                    claudeSessionId: conversation.claudeSessionId
                )),
                title: open.title,
                // "Kill Session" in the terminal menu = Close conversation: ends tmux, keeps
                // the Claude conversation resumable.
                onKill: {
                    try await store.closeConversation(conversation, config: connection.config)
                }
            )
        } else {
            ContentUnavailableView(
                "Terminal Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("The private key for this host is unavailable. Edit the host and save its key again.")
            )
        }
    }
}

private struct TodoRow: View {
    let todo: Todo
    let status: ConversationStatus?
    let isOpening: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.completed ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.completed ? "Mark not done" : "Mark done")

            Text(todo.title)
                .strikethrough(todo.completed)
                .foregroundStyle(todo.completed ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isOpening {
                ProgressView()
            } else if let status {
                ConversationBadge(status: status)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ConversationBadge: View {
    let status: ConversationStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Conversation \(label)")
    }

    private var label: String {
        switch status {
        case .busy: "Busy"
        case .waiting: "Waiting"
        case .idle: "Idle"
        case .unknown: "Open"
        case .closed: "Closed"
        }
    }

    private var color: Color {
        switch status {
        case .busy: .blue
        case .waiting: .orange
        case .idle: .green
        case .unknown: .secondary
        case .closed: .gray
        }
    }
}

private struct AddTodoSheet: View {
    let onAdd: (TodoSection, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var section: TodoSection = .i
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Picker("Section", selection: $section) {
                    ForEach(TodoSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                // A plain TextField keeps the keyboard's dictation button available.
                TextField("Title", text: $title, axis: .vertical)
                    .focused($titleFocused)
            }
            .navigationTitle("New Todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(section, title.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.medium])
    }
}
