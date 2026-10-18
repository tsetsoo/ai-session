import AISessionCore
import SwiftData
import SwiftUI

/// Todos in inset-grouped sections, each headed by its code and computer. Tapping a todo calls
/// `onOpen`; the caller owns navigation to its conversation. Given a `selection` (the Mac list
/// column) rows select by todo id instead.
struct TodoListView: View {
    let sections: [TodoSection]
    let onOpen: (Todo) -> Void
    private let query: String
    private let selection: Binding<String?>?

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var actions = ConversationRowActions()
    @State private var linkTarget: Todo?
    @State private var addSection: TodoSection?

    init(sections: [TodoSection], query: String = "", selection: Binding<String?>? = nil,
         onOpen: @escaping (Todo) -> Void) {
        self.sections = sections
        self.query = query
        self.selection = selection
        self.onOpen = onOpen
    }

    private var store: TodoHubStore { model.store }

    var body: some View {
        let board = model.board
        SelectableList(selection: selection) {
            ListStatusBanner(store: store)
            ForEach(sections) { section in
                sectionView(section, board: board)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .conversationActions(actions, store: store, hosts: hosts)
        .sheet(item: $linkTarget) { todo in
            LinkConversationSheet(todo: todo, store: store)
        }
        .sheet(item: $addSection) { section in
            AddTodoSheet(section: section, projects: store.projects) { section, title, projectId in
                Task { await store.createTodo(section: section, title: title, projectId: projectId) }
            }
        }
    }

    private func sectionView(_ section: TodoSection, board: ConversationBoard) -> some View {
        Section {
            let all = store.todos(in: section)
            let todos = all.filter { ListSearch.matches(query, $0.title) }
            if !all.isEmpty && todos.isEmpty {
                Text("No results for “\(query)” in \(section.rawValue)")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: DS.rowMinHeight)
            } else if todos.isEmpty {
                HStack {
                    Text("No todos in \(section.rawValue)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("New Todo") { addSection = section }
                        .buttonStyle(.borderless)
                        .tint(DS.accent)
                        .disabled(store.isOffline)
                }
                .frame(minHeight: DS.rowMinHeight)
            }
            ForEach(todos) { todo in
                row(todo, board: board)
            }
        } header: {
            // One section (the Mac list column) is already named above the list.
            if sections.count > 1 {
                HStack {
                    Text(section.rawValue).fontWeight(.semibold)
                    Spacer()
                    if let mapping = store.sectionComputers[section] {
                        Text(mapping.computer.name).foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                .textCase(nil)
            }
        }
    }

    private func row(_ todo: Todo, board: ConversationBoard) -> some View {
        let conversation = store.conversations[todo.id]
        let status = board.status(forTodo: todo.id)
        let isRunning = status.map { $0 != .closed } ?? false
        let canChange = !store.isOffline
        return TodoRow(
            todo: todo,
            conversation: conversation,
            status: status,
            now: .now,
            isBusy: actions.inFlight.contains(todo.id),
            canToggle: canChange,
            projectName: store.project(id: todo.projectId)?.name,
            onToggle: { toggle(todo) }
        )
        .tag(todo.id)
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
                Button(role: .destructive) {
                    Task { await store.delete(todo) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                if let conversation, isRunning {
                    Button {
                        actions.close(conversation, store: store, hosts: hosts)
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
            Button {
                onOpen(todo)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            MuteNotificationsButton(todoID: todo.id)
            // Project ▸ (disabled offline or without projects).
            TodoProjectMenu(todo: todo, store: store)
            // Offline, the changing items are left out, like the swipes.
            if canChange {
                if let conversation {
                    Button {
                        actions.close(conversation, store: store, hosts: hosts)
                    } label: {
                        Label("Close Conversation", systemImage: "xmark.circle")
                    }
                    .disabled(!isRunning)
                    Button(role: .destructive) {
                        actions.deleteTarget = conversation
                    } label: {
                        Label("Delete Conversation…", systemImage: "trash.slash")
                    }
                } else {
                    Button {
                        linkTarget = todo
                    } label: {
                        Label("Link Conversation…", systemImage: "link")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    Task { await store.delete(todo) }
                } label: {
                    Label("Delete Todo", systemImage: "trash")
                }
            }
        }
    }

    private func toggle(_ todo: Todo) {
        Task { await store.toggle(todo) }
    }
}

#if DEBUG
#Preview("Todos") {
    NavigationStack {
        TodoListView(sections: TodoSection.allCases) { _ in }
            .navigationTitle("Todos")
    }
    .environment(AppModel(demo: true))
    .modelContainer(for: HostEntity.self, inMemory: true)
}
#endif
