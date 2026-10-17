import AISessionCore
import SwiftData
import SwiftUI

/// Conversations across all computers, filtered to Needs you, Running or All. Tapping one calls
/// `onOpen` with its todo; the caller owns navigation.
struct ConversationListView: View {
    enum Filter: Hashable, CaseIterable {
        case needsYou, running, all
    }

    @Binding var filter: Filter
    let onOpen: (Todo) -> Void

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var actions = ConversationRowActions()

    init(filter: Binding<Filter>, onOpen: @escaping (Todo) -> Void) {
        _filter = filter
        self.onOpen = onOpen
    }

    private var store: TodoHubStore { model.store }

    var body: some View {
        let board = model.board
        let conversations = switch filter {
        case .needsYou: board.needsYou
        case .running: board.runningNow
        case .all: board.all
        }
        let todos = Dictionary(store.todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        TimelineView(.everyMinute) { context in
            List {
                ListStatusBanner(store: store)
                Section {
                    filterPicker(needsYouCount: board.needsYou.count)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if conversations.isEmpty {
                    Section {
                        emptyState
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
            isBusy: actions.inFlight.contains(conversation.todoId)
        )
        .rowTap(open)
        .conversationRowMenu(conversation, isRunning: status != .closed, actions: actions,
                             store: store, hosts: hosts, open: open)
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
