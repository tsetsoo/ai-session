import AISessionCore
import SwiftData
import SwiftUI

/// Conversations across all computers, filtered to Needs you, To review, Working or All. Tapping one calls
/// `onOpen` with its todo; the caller owns navigation. Given a `selection` (the Mac list column)
/// rows select by todo id instead, and the sidebar picks the filter.
struct ConversationListView: View {
    enum Filter: Hashable, CaseIterable {
        case needsYou, review, working, all

        /// Needs you when something does, else To review.
        static func initial(needsYouCount: Int) -> Filter {
            needsYouCount > 0 ? .needsYou : .review
        }

        func conversations(_ board: ConversationBoard) -> [Conversation] {
            switch self {
            case .needsYou: board.needsYou
            case .review: board.review
            case .working: board.working
            case .all: board.all
            }
        }
    }

    @Binding var filter: Filter
    let onOpen: (Todo) -> Void
    private let showsFilterPicker: Bool
    /// ⌘1–⌘9 next to the first nine conversations of the filter.
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
        let filtered = filter.conversations(board)
        let conversations = filtered.filter { conversation in
            let todo = todos[conversation.todoId]
            return ListSearch.matches(query, todo?.title,
                                      RowText.conversationSearchText(conversation, section: todo?.section),
                                      conversation.statusMessage)
        }
        let shortcuts: [String: Int] = showsShortcuts
            ? Dictionary(uniqueKeysWithValues: filtered.prefix(9).enumerated().map { ($1.listKey, $0 + 1) })
            : [:]
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
                    if filtered.isEmpty && !store.hasLoadedOnce {
                        // Before the first sync "Nothing needs you" would be a guess.
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: DS.rowMinHeight)
                    } else if filtered.isEmpty {
                        emptyState
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(conversations, id: \.listKey) { conversation in
                        row(conversation, todo: todos[conversation.todoId], board: board,
                            shortcut: shortcuts[conversation.listKey])
                    }
                } footer: {
                    #if os(iOS)
                    Text("Swipe left to close or delete. Swipe right to copy the resume command.")
                    #endif
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            // Background: a failure shows in the banner, not in the shell's Todos alert.
            await store.refresh(trigger: .background)
            await model.refreshLiveness(hosts: hosts)
        }
        .conversationActions(actions, store: store, hosts: hosts)
    }

    private func filterPicker(needsYouCount: Int) -> some View {
        Picker("Show", selection: $filter) {
            Text(needsYouCount > 0 ? "Needs you \(needsYouCount)" : "Needs you").tag(Filter.needsYou)
            Text("To review").tag(Filter.review)
            Text("Working").tag(Filter.working)
            Text("All").tag(Filter.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func row(_ conversation: Conversation, todo: Todo?, board: ConversationBoard,
                     shortcut: Int?) -> some View {
        let status = board.status(of: conversation)
        let open: (() -> Void)? = todo.map { todo in
            {
                model.selectedConversationID = conversation.listKey
                onOpen(todo)
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
            },
            shortcut: shortcut
        )
        .tag(conversation.listKey)
        .rowTap(selection == nil ? open : nil)
        .conversationRowMenu(conversation, todo: todo, isRunning: status != .closed, actions: actions,
                             store: store, hosts: hosts, open: open)
    }

    @ViewBuilder private var emptyState: some View {
        switch filter {
        case .needsYou:
            ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle")
        case .review:
            ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle")
        case .working:
            ContentUnavailableView {
                Label("Nothing working", systemImage: "bolt")
            } description: {
                Text("Open a todo to start a conversation.")
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
