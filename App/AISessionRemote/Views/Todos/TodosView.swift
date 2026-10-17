import AISessionCore
import SwiftData
import SwiftUI

/// Todos grouped by section (Sp / I / Si / P). Tapping a todo opens its AI conversation on the
/// section's computer over a direct SSH connection; the hub only stores the mapping.
struct TodosView: View {
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var store = TodoHubStore()
    @State private var showingSettings = false
    @State private var showingComputers = false
    @State private var showingAdd = false
    @State private var openTodoID: String?
    @State private var openingTodoID: String?
    @State private var missingHost: Computer?
    @State private var newHostPrefill: HostEditorPrefill?
    @State private var linkTarget: Todo?
    @State private var deleteTarget: Todo?
    @State private var showingNewFromConversation = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Todos")
                .toolbar { toolbar }
                .refreshable { await store.refresh() }
                .navigationDestination(item: $openTodoID) { todoID in
                    conversationDestination(todoID)
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
        .sheet(item: $newHostPrefill) { prefill in
            // Create mode: the host and its key are saved together, and Cancel leaves nothing.
            HostEditorView(prefill: prefill)
        }
        .sheet(item: $linkTarget) { todo in
            LinkConversationSheet(todo: todo, store: store)
        }
        .sheet(isPresented: $showingNewFromConversation) {
            NewTodoFromConversationSheet(store: store)
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { todo in
            Button("Delete Conversation", role: .destructive) { deleteConversation(of: todo) }
            Button("Cancel", role: .cancel) {}
        } message: { todo in
            if let conversation = store.conversations[todo.id] {
                Text(conversation.deleteConfirmationMessage)
            }
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
                } else if let issue = store.backgroundIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
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
                .onTapGesture { openTodoID = todo.id }
                .contextMenu {
                    if store.conversations[todo.id] != nil {
                        Button(role: .destructive) {
                            deleteTarget = todo
                        } label: {
                            Label("Delete Conversation…", systemImage: "trash.slash")
                        }
                        .disabled(store.isOffline)
                    } else {
                        Button {
                            linkTarget = todo
                        } label: {
                            Label("Link Existing Conversation…", systemImage: "link")
                        }
                        .disabled(store.isOffline)
                    }
                }
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
            // Tap: new todo. Hold (iOS) / arrow (Mac): new todo from an existing conversation.
            Menu {
                Button {
                    showingAdd = true
                } label: {
                    Label("New Todo", systemImage: "plus")
                }
                Button {
                    showingNewFromConversation = true
                } label: {
                    Label("New Todo from Conversation…", systemImage: "text.bubble")
                }
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                showingAdd = true
            }
            .accessibilityLabel("Add Todo")
            .disabled(!store.isConfigured || store.isOffline)
        }
    }

    // MARK: Conversations

    private func deleteConversation(of todo: Todo) {
        guard let conversation = store.conversations[todo.id] else { return }
        guard matchingHost(for: conversation.computer) != nil else {
            missingHost = conversation.computer
            return
        }
        openingTodoID = todo.id
        Task {
            defer { openingTodoID = nil }
            do {
                let config = try HostLookup.config(for: conversation.computer, in: hosts)
                try await store.deleteConversation(conversation, config: config)
            } catch {
                store.errorMessage = TodoHubStore.message(for: error)
            }
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
        newHostPrefill = HostEditorPrefill(
            displayName: computer.name,
            hostname: computer.hostname,
            port: computer.port,
            username: computer.username
        )
    }

    /// Pushed at once on tap; the frame shows preparing, problems and the terminal itself.
    @ViewBuilder
    private func conversationDestination(_ todoID: String) -> some View {
        if let todo = store.todos.first(where: { $0.id == todoID }) {
            TodoConversationScreen(todo: todo, store: store) { openTodoID = nil }
        } else {
            ContentUnavailableView("Todo Not Found", systemImage: "checklist")
        }
    }
}

/// The conversation frame for a tapped todo. A tap is an explicit open, so the loader starts
/// (or resumes) the conversation as soon as the frame appears.
private struct TodoConversationScreen: View {
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
        _loader = State(initialValue: ConversationLoader(
            todo: todo,
            dependencies: .live(store: store, hosts: { hostList.hosts })
        ))
    }

    var body: some View {
        ConversationFrame(todo: todo, loader: loader, store: store, onDeleted: onDeleted)
            .onChange(of: hosts) { _, hosts in hostList.hosts = hosts }
            .task {
                hostList.hosts = hosts
                guard loader.phase == .idle else { return }
                await loader.start()
            }
    }
}

/// The current saved hosts, read by the loader on every resolve (a host added from the frame's
/// Set Up Access then counts on retry).
@MainActor
private final class HostList {
    var hosts: [HostEntity] = []
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
