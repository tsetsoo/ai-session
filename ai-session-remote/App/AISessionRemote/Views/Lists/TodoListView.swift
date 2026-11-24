import AISessionCore
import SwiftData
import SwiftUI

/// A project’s todos or the full todo list grouped by project or status.
struct TodoListView: View {
    let project: Project?
    let onOpen: (Todo) -> Void
    private let onRestart: ((Todo) -> Void)?
    private let query: String
    private let selection: Binding<String?>?
    private let grouping: Binding<TodoGrouping>?

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var actions = ConversationRowActions()
    /// Scheduled todos (made by scheduler jobs) shown or hidden, kept per device.
    @AppStorage("showScheduledTodos") private var showScheduled = true
    @State private var linkTarget: Todo?
    /// Delete Todo… asks first.
    @State private var deleteTarget: Todo?

    init(project: Project? = nil, query: String = "", selection: Binding<String?>? = nil,
         grouping: Binding<TodoGrouping>? = nil,
         onRestart: ((Todo) -> Void)? = nil, onOpen: @escaping (Todo) -> Void) {
        self.project = project
        self.query = query
        self.selection = selection
        self.grouping = grouping
        self.onRestart = onRestart
        self.onOpen = onOpen
    }

    private var store: TodoHubStore { model.store }

    var body: some View {
        let board = model.board
        SelectableList(selection: selection) {
            ListStatusBanner(store: store)
            if store.todos.contains(where: { $0.scheduledJobId != nil }) {
                Toggle("Show scheduled", isOn: $showScheduled)
            }
            if let grouping {
                Section {
                    Picker("Group by", selection: grouping) {
                        ForEach([TodoGrouping.project, .status], id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .skinnedRows()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            #if os(macOS)
            TodoHoldDropArea(store: store, status: .active)
            #endif
            if let project {
                Section {
                    InlineTodoAdd(project: project)
                    let todos = searched.filter(isInMainList)
                    if todos.isEmpty {
                        if !store.hasLoadedOnce { ProgressView() }
                        else if !query.isEmpty { ContentUnavailableView.search(text: query) }
                        else { Text("No todos").foregroundStyle(.secondary) }
                    }
                    ForEach(todos) { todo in row(todo, board: board) }
                }
                .skinnedRows()
                .todoStatusDropTarget(store: store, status: .active)
            } else if grouping?.wrappedValue == .status {
                let groups = TodoGrouping.byStatus(searched.filter(isInMainList)) { board.status(forTodo: $0) }
                if groups.isEmpty { emptyGroups }
                ForEach(groups) { group in
                    groupView(group.status.label, detail: nil, todos: group.todos, addTo: nil, board: board)
                }
            } else {
                let groups = TodoGrouping.byProject(searched.filter(isInMainList), projects: store.projects)
                if groups.isEmpty { emptyGroups }
                ForEach(groups) { group in
                    groupView(group.title, detail: group.project?.computer.name, todos: group.todos,
                              addTo: group.project, board: board)
                }
                if grouping == nil {
                    let completed = searched.filter { $0.completed && isInMainList($0) }
                    if !completed.isEmpty {
                        groupView("Completed", detail: nil, todos: completed, addTo: nil, board: board)
                    }
                }
            }
            ForEach([TodoWorkStatus.waiting, .onHold], id: \.self) { status in
                let items = searched.filter { $0.workStatus == status && (showScheduled || $0.scheduledJobId == nil) }
                if showsWorkStatusSection(hasItems: !items.isEmpty) {
                    Section {
                        #if os(macOS)
                        if items.isEmpty {
                            TodoHoldDropArea(store: store, status: status)
                        }
                        #endif
                        ForEach(items) { todo in
                            row(todo, board: board)
                        }
                    } header: {
                        Text("\(status.label) (\(items.count))").textCase(nil)
                            .todoStatusDropTarget(store: store, status: status)
                    }
                    .skinnedRows()
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .conversationActions(actions, store: store, hosts: hosts)
        .sheet(item: $linkTarget) { todo in
            LinkConversationSheet(todo: todo, store: store)
        }
        .todoDeleteConfirmation($deleteTarget, store: store)
    }

    /// Every todo matching the search, for the project and status groupings.
    private var searched: [Todo] {
        let todos = project.map { store.todos(inProject: $0.id) } ?? store.todos
        return todos.filter { ListSearch.matches(query, $0.title) }
    }

    private func isInMainList(_ todo: Todo) -> Bool {
        guard showScheduled || todo.scheduledJobId == nil else { return false }
        return todo.workStatus == .active
    }

    @ViewBuilder
    private var emptyGroups: some View {
        Section {
            if !store.hasLoadedOnce {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: DS.rowMinHeight)
            } else if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Text("No open todos")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: DS.rowMinHeight, alignment: .leading)
            }
        }
        .skinnedRows()
    }

    /// A project or status group: just its todos, with an add row when it is a project.
    private func groupView(_ title: String, detail: String?, todos: [Todo], addTo project: Project?,
                           board: ConversationBoard) -> some View {
        Section {
            if let project {
                InlineTodoAdd(project: project)
            }
            ForEach(todos) { todo in
                row(todo, board: board)
            }
        } header: {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                if let detail {
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .textCase(nil)
            .todoStatusDropTarget(store: store, status: .active)
        }
        .skinnedRows()
    }

    private func row(_ todo: Todo, board: ConversationBoard) -> some View {
        let conversation = store.mostUrgent(forTodo: todo.id)
        let status = board.status(forTodo: todo.id)
        let isRunning = status.map { $0 != .closed } ?? false
        let canChange = !store.isOffline
        return TodoRow(
            todo: todo,
            conversation: conversation,
            status: status,
            isBusy: actions.inFlight.contains(todo.id),
            canToggle: canChange,
            projectName: store.project(id: todo.projectId)?.name,
            scheduledLabel: store.scheduledLabel(for: todo),
            onToggle: { toggle(todo) },
            onResume: conversation.flatMap { conversation in
                conversation.paused?.offer == true && canChange
                    ? { actions.resumeAfterLimit(conversation, store: store, hosts: hosts) } : nil
            }
        )
        .tag(todo.id)
        .skinnedRow(selected: selection?.wrappedValue == todo.id)
        .rowTap(selection == nil ? { onOpen(todo) } : nil)
        // Offline, the swipes are left out: a disabled full swipe can still fire.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if canChange {
                Button {
                    toggle(todo)
                } label: {
                    Label(todo.completed ? "Undo" : "Done",
                          systemImage: todo.completed ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(DS.accentSolid)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canChange {
                // Not `.destructive`: that role animates the row away before the confirmation.
                Button {
                    deleteTarget = todo
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                .tint(DS.destructive)
                if let conversation, isRunning {
                    Button {
                        actions.requestClose(conversation, store: store, hosts: hosts)
                    } label: {
                        Label("Close", systemImage: "xmark.circle")
                    }
                    .tint(.gray)
                } else if conversation == nil {
                    Button {
                        linkTarget = todo
                    } label: {
                        Label("Link…", systemImage: "link")
                    }
                    .tint(.gray)
                }
            }
        }
        .contextMenu {
            MuteNotificationsButton(todoID: todo.id, actions: actions)
            RenameTodoButton(todo: todo, store: store) { actions.renameTarget = $0 }
            if canChange {
                TodoHoldButton(todo: todo, store: store)
                if conversation != nil, let onRestart {
                    Button { onRestart(todo) } label: {
                        Label("Restart…", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                if conversation == nil {
                    Button { linkTarget = todo } label: {
                        Label("Link Conversation…", systemImage: "link")
                    }
                }
                Divider()
                if let conversation {
                    Button {
                        actions.requestClose(conversation, store: store, hosts: hosts)
                    } label: {
                        Label("Close Conversation", systemImage: "xmark.circle")
                    }
                    .disabled(!isRunning)
                    Button(role: .destructive) {
                        actions.deleteTarget = conversation
                    } label: {
                        Label(conversation.removalActionTitle + "…", systemImage: "trash.slash")
                    }
                }
                Button(role: .destructive) {
                    deleteTarget = todo
                } label: {
                    Label("Delete Todo…", systemImage: "trash")
                }
                Divider()
            }
            TodoProjectMenu(todo: todo, store: store)
        }
        .todoDragSource(todo, store: store)
        .todoStatusDropTarget(store: store, status: todo.workStatus)
    }

    private func toggle(_ todo: Todo) {
        Task { await store.toggle(todo) }
    }
}

#if DEBUG
#Preview("Todos") {
    NavigationStack {
        TodoListView() { _ in }
            .navigationTitle("Todos")
    }
    .environment(AppModel(demo: true))
    .modelContainer(for: HostEntity.self, inMemory: true)
}
#endif
