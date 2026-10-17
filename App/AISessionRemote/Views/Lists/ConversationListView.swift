import AISessionCore
import SwiftData
import SwiftUI

/// Conversations across all computers, filtered to Needs you, Running or All. Tapping one calls
/// `onOpen` with its todo; the caller owns navigation. Given a `selection` (the Mac list column)
/// rows select by todo id instead, and the sidebar picks the filter.
struct ConversationListView: View {
    enum Filter: Hashable, CaseIterable {
        case needsYou, running, all

        /// Needs you when something does, else Running.
        static func initial(needsYouCount: Int) -> Filter {
            needsYouCount > 0 ? .needsYou : .running
        }
    }

    @Binding var filter: Filter
    let onOpen: (Todo) -> Void
    private let showsFilterPicker: Bool
    /// ⌘1–⌘9 next to the first nine running conversations.
    private let showsShortcuts: Bool
    private let query: String
    private let selection: Binding<String?>?

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var actions = ConversationRowActions()

    init(filter: Binding<Filter>, showsFilterPicker: Bool = true, showsShortcuts: Bool = false,
         query: String = "", selection: Binding<String?>? = nil, onOpen: @escaping (Todo) -> Void) {
        _filter = filter
        self.showsFilterPicker = showsFilterPicker
        self.showsShortcuts = showsShortcuts
        self.query = query
        self.selection = selection
        self.onOpen = onOpen
    }

    private var store: TodoHubStore { model.store }

    var body: some View {
        let board = model.board
        let todos = Dictionary(store.todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let filtered = switch filter {
        case .needsYou: board.needsYou
        case .running: board.runningNow
        case .all: board.all
        }
        let conversations = filtered.filter { conversation in
            let todo = todos[conversation.todoId]
            return ListSearch.matches(query, todo?.title, RowText.conversationMeta(conversation, section: todo?.section),
                                      conversation.statusMessage)
        }
        TimelineView(.everyMinute) { context in
            SelectableList(selection: selection) {
                ListStatusBanner(store: store)
                if showsFilterPicker {
                    Section {
                        filterPicker(needsYouCount: board.needsYou.count)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if conversations.isEmpty {
                    Section {
                        if filtered.isEmpty {
                            emptyState
                        } else {
                            ContentUnavailableView.search(text: query)
                        }
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(conversations, id: \.todoId) { conversation in
                            row(conversation, todo: todos[conversation.todoId], board: board, now: context.date)
                        }
                    } footer: {
                        #if os(iOS)
                        Text("Swipe left to close or delete. Swipe right to copy the resume command.")
                        #endif
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .task { await model.refreshLiveness(hosts: hosts) }
        .refreshable {
            // Background: a failure shows in the banner, not in the Todos list's alert.
            await store.refresh(trigger: .background)
            await model.refreshLiveness(hosts: hosts)
        }
        .conversationActions(actions, store: store, hosts: hosts)
    }

    private func filterPicker(needsYouCount: Int) -> some View {
        Picker("Show", selection: $filter) {
            Text(needsYouCount > 0 ? "Needs you \(needsYouCount)" : "Needs you").tag(Filter.needsYou)
            Text("Running").tag(Filter.running)
            Text("All").tag(Filter.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func row(_ conversation: Conversation, todo: Todo?, board: ConversationBoard, now: Date) -> some View {
        let status = board.status(forTodo: conversation.todoId) ?? .closed
        let open: (() -> Void)? = todo.map { todo in { onOpen(todo) } }
        return ConversationRow(
            title: todo?.title ?? "Conversation",
            section: todo?.section,
            conversation: conversation,
            status: status,
            now: now,
            isBusy: actions.inFlight.contains(conversation.todoId),
            shortcut: showsShortcuts ? Self.shortcut(for: conversation, board: board) : nil
        )
        .tag(conversation.todoId)
        .rowTap(selection == nil ? open : nil)
        .conversationRowMenu(conversation, isRunning: status != .closed, actions: actions,
                             store: store, hosts: hosts, open: open)
    }

    /// Its ⌘n number in Running now, if it is among the first nine.
    private static func shortcut(for conversation: Conversation, board: ConversationBoard) -> Int? {
        (1...9).first { board.conversation(atShortcut: $0)?.todoId == conversation.todoId }
    }

    @ViewBuilder private var emptyState: some View {
        switch filter {
        case .needsYou:
            ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle")
        case .running:
            ContentUnavailableView {
                Label("No conversations running", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Open a todo to start one.")
            }
        case .all:
            ContentUnavailableView {
                Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Open a todo to start one.")
            }
        }
    }
}

#if DEBUG
private struct ConversationListPreview: View {
    @State private var filter = ConversationListView.Filter.needsYou

    var body: some View {
        NavigationStack {
            ConversationListView(filter: $filter) { _ in }
                .navigationTitle("Conversations")
        }
    }
}

#Preview("Conversations") {
    ConversationListPreview()
        .environment(AppModel(demo: true))
        .modelContainer(for: HostEntity.self, inMemory: true)
}
#endif
