import AISessionCore
import SwiftData
import SwiftUI

/// Something the Mac shell asks of the frame showing `todoID`. The frame clears it once handled.
struct FrameRequest: Equatable {
    enum Kind: Equatable {
        /// The selection settled on a running conversation.
        case attach
        /// The conversation stopped running, or moved to its own window: back to Start / Resume.
        case detach
        /// ⏎, a double-click or Open: get-or-create on the hub.
        case start
    }

    let kind: Kind
    let todoID: String
    /// Two equal requests in a row still both arrive.
    let id = UUID()
}

/// The conversation frame for a todo. Showing it never starts anything. The shell's
/// `SelectionAttacher` sends `.attach` for a running conversation, and ⏎, a double-click or the
/// frame's own button starts one; until then the frame shows Start / Resume.
struct TodoConversationScreen: View {
    let todo: Todo
    let store: TodoHubStore
    @Binding var request: FrameRequest?
    /// Drawn in the terminal area instead of the loader's state (see `FramePlaceholder`).
    let placeholder: FramePlaceholder?
    @Environment(AppModel.self) private var appModel: AppModel?

    private var shown: Conversation? {
        store.displayed(forTodo: todo.id, selectedKey: appModel?.selectedConversationID)
    }
    /// Popped out into its own window: this frame holds no terminal and ignores requests.
    let isSuspended: Bool
    /// Another mounted conversation is the one on screen. This one keeps its terminal.
    let isFrontmost: Bool
    /// See `ConversationFrame.sharesColumn`.
    let sharesColumn: Bool
    /// The column toolbar's commands. Only the frontmost frame acts on one.
    var toolbarRequest: Binding<ConversationToolbarRequest?> = .constant(nil)
    let onPopOut: (() -> Void)?
    let onDeleted: () -> Void

    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var hostList: HostList
    @State private var loader: ConversationLoader
    /// Mac: the todo's open conversations side by side instead of one at a time.
    @State private var sideBySide = false
    /// Continue with This was asked for while others are still working: confirm first.
    @State private var continuing: Conversation?
    @State private var switcherError: String?

    init(todo: Todo, store: TodoHubStore, request: Binding<FrameRequest?> = .constant(nil),
         placeholder: FramePlaceholder? = nil, isSuspended: Bool = false, isFrontmost: Bool = true,
         sharesColumn: Bool = false, toolbarRequest: Binding<ConversationToolbarRequest?> = .constant(nil),
         onPopOut: (() -> Void)? = nil, onDeleted: @escaping () -> Void) {
        self.todo = todo
        self.store = store
        _request = request
        self.placeholder = placeholder
        self.isSuspended = isSuspended
        self.isFrontmost = isFrontmost
        self.sharesColumn = sharesColumn
        self.toolbarRequest = toolbarRequest
        self.onPopOut = onPopOut
        self.onDeleted = onDeleted
        let hostList = HostList()
        _hostList = State(initialValue: hostList)
        var dependencies = ConversationLoader.Dependencies.live(store: store, hosts: { hostList.hosts })
        #if DEBUG
        if DemoFixtures.isEnabled { dependencies = DemoFixtures.loaderDependencies() }
        #endif
        _loader = State(initialValue: ConversationLoader(todo: todo, dependencies: dependencies))
    }

    private var todoConversations: [Conversation] { store.conversations(forTodo: todo.id) }

    var body: some View {
        VStack(spacing: 0) {
            if !isSuspended {
                ConversationSwitcherBar(
                    conversations: todoConversations,
                    selectedKey: shown?.listKey,
                    sideBySide: $sideBySide,
                    onSelect: { appModel?.selectedConversationID = $0.listKey },
                    onContinue: askToContinue,
                    onReopenClosed: reopenClosed,
                    failed: ConversationSwitcherModel.failedAttempts(
                        store.researchIdea(forTodo: todo.id)?.attempts ?? [], conversations: todoConversations
                    ),
                    onRetry: retryAttempt
                )
            }
            #if os(macOS)
            if sideBySide, ConversationSwitcherModel.showsSwitcher(todoConversations), !isSuspended {
                ConversationGrid(todo: todo, store: store, conversations: ConversationSwitcherModel.tabs(todoConversations),
                                 hostList: hostList,
                                 toolbarKey: ConversationSwitcherModel.toolbarKey(
                                     tabs: ConversationSwitcherModel.tabs(todoConversations), selectedKey: shown?.listKey
                                 ),
                                 screenFrontmost: isFrontmost && !isSuspended,
                                 toolbarRequest: toolbarRequest, onContinue: askToContinue)
            } else {
                frame
            }
            #else
            frame
            #endif
        }
            .confirmationDialog(
                continuingTitle,
                isPresented: Binding(get: { continuing != nil }, set: { if !$0 { continuing = nil } }),
                titleVisibility: .visible
            ) {
                Button("Close Them and Continue", role: .destructive) {
                    if let chosen = continuing { continueWith(chosen) }
                }
            } message: {
                Text("They stop now and can be opened again from this todo.")
            }
            .alert("Couldn't Switch Conversations", isPresented: Binding(
                get: { switcherError != nil }, set: { if !$0 { switcherError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(switcherError ?? "")
            }
            .onChange(of: ConversationSwitcherModel.showsSwitcher(todoConversations)) { _, shows in
                if !shows { sideBySide = false }
            }
            .onChange(of: hosts) { _, hosts in hostList.hosts = hosts }
            .task(id: store.revision) {
                // A research todo's attempts (failed ones get Retry in the switcher).
                if todo.scheduledJobId != nil, !isSuspended { await store.loadAllIdeas() }
            }
            .onChange(of: request, initial: true) { _, request in handle(request) }
            .onChange(of: shown?.listKey) { _, _ in
                // Switching conversations of the todo already on screen. An idle frame waits
                // for an explicit start, so selecting a row does not attach by itself.
                guard let shown, !isSuspended, case .ready = loader.phase else { return }
                loader.show(shown)
            }
            .onChange(of: isSuspended) { _, suspended in
                // The pop-out window attaches on its own; don't stay attached here too.
                if suspended { loader.reset() }
            }
            .task { hostList.hosts = hosts }
    }

    private func handle(_ request: FrameRequest?) {
        guard let request, request.todoID == todo.id else { return }
        self.request = nil
        hostList.hosts = hosts
        switch request.kind {
        case .attach:
            // Only into an idle frame: an explicit start or a problem card stays as it is.
            guard !isSuspended, loader.phase == .idle else { return }
            loader.attachIfRunning(shown)
        case .detach:
            guard loader.phase != .idle, loader.phase != .preparing else { return }
            loader.reset()
        case .start:
            // Another conversation of this todo replaces the one on screen. A problem retries.
            // No conversation yet: the tool step confirms before anything is created.
            guard !isSuspended else { return }
            if let shown, shown.status != .closed {
                loader.show(shown)
                if case .ready = loader.phase { return }
            }
            guard loader.phase == .idle || isProblem else { return }
            guard ConversationStart.hasStartedSession(shown?.sessionId) || isProblem else { return }
            Task { await loader.start() }
        }
    }

    private var continuingTitle: String {
        guard let chosen = continuing else { return "" }
        let busy = ConversationSwitcherModel.busyOthers(continuing: chosen, in: todoConversations)
        let names = busy.map(ConversationSwitcherModel.label).joined(separator: ", ")
        return busy.count == 1 ? "\(names) is still working. Close it?" : "\(names) are still working. Close them?"
    }

    /// Continue with This: asks first when another conversation is still working.
    private func askToContinue(_ chosen: Conversation) {
        if ConversationSwitcherModel.busyOthers(continuing: chosen, in: todoConversations).isEmpty {
            continueWith(chosen)
        } else {
            continuing = chosen
        }
    }

    private func continueWith(_ chosen: Conversation) {
        continuing = nil
        sideBySide = false
        appModel?.selectedConversationID = chosen.listKey
        let hosts = self.hosts
        Task {
            do {
                try await store.continueWith(chosen) { try HostLookup.config(for: $0.computer, in: hosts) }
                if case .ready = loader.phase { loader.show(chosen) } else { loader.attachIfRunning(chosen) }
            } catch {
                switcherError = TodoHubStore.message(for: error)
            }
        }
    }

    private func retryAttempt(_ attempt: IdeaAttempt) {
        Task {
            do {
                try await store.retryAttempt(attempt)
            } catch {
                switcherError = TodoHubStore.message(for: error)
            }
        }
    }

    private func reopenClosed() {
        let closed = todoConversations.filter { $0.status == .closed }
        Task {
            do {
                try await store.reopen(closed)
            } catch {
                switcherError = TodoHubStore.message(for: error)
            }
        }
    }

    private var isProblem: Bool {
        if case .problem = loader.phase { return true }
        return false
    }

    private var frame: ConversationFrame {
        #if DEBUG
        if DemoFixtures.isEnabled {
            return ConversationFrame(todo: todo, loader: loader, store: store, placeholder: placeholder,
                                     onPopOut: onPopOut, isFrontmost: isFrontmost, sharesColumn: sharesColumn,
                                     toolbarRequest: toolbarRequest, onDeleted: onDeleted,
                                     makeTransport: { _, _ in DemoTransport() })
        }
        #endif
        return ConversationFrame(todo: todo, loader: loader, store: store, placeholder: placeholder,
                                 onPopOut: onPopOut, isFrontmost: isFrontmost, sharesColumn: sharesColumn,
                                 toolbarRequest: toolbarRequest, onDeleted: onDeleted)
    }
}

/// The current saved hosts, read by the loader on every resolve (a host added from the frame's
/// Set Up Access then counts on retry).
@MainActor
private final class HostList {
    var hosts: [HostEntity] = []
}

#if os(macOS)
/// Side by side: each open conversation in its own pane, two columns, rows as needed. Only these
/// panes are mounted (hidden views would still lay out).
private struct ConversationGrid: View {
    let todo: Todo
    let store: TodoHubStore
    let conversations: [Conversation]
    let hostList: HostList
    /// The pane the column toolbar acts on (the selected tab); the only frontmost one.
    let toolbarKey: String?
    let screenFrontmost: Bool
    let toolbarRequest: Binding<ConversationToolbarRequest?>
    let onContinue: (Conversation) -> Void

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 6),
            count: ConversationSwitcherModel.gridColumns(conversations.count)
        )
        GeometryReader { geometry in
            let rows = (conversations.count + columns.count - 1) / columns.count
            // Up to two rows fill the height; more scroll (each pane keeps a usable height).
            let height = max(240, (geometry.size.height - 6) / CGFloat(min(rows, 2)) - 6)
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(conversations, id: \.listKey) { conversation in
                        let frontmost = ConversationSwitcherModel.paneIsFrontmost(
                            screenFrontmost: screenFrontmost, suspended: false,
                            paneKey: conversation.listKey, toolbarKey: toolbarKey
                        )
                        ConversationPane(todo: todo, store: store, conversation: conversation, hostList: hostList,
                                         isFrontmost: frontmost, isOnScreen: screenFrontmost,
                                         toolbarRequest: frontmost ? toolbarRequest : .constant(nil),
                                         onContinue: { onContinue(conversation) })
                            .frame(height: height)
                    }
                }
                .padding(6)
            }
        }
    }
}

/// One conversation of the grid: its header and its own terminal, acting on that conversation.
private struct ConversationPane: View {
    let todo: Todo
    let store: TodoHubStore
    let conversation: Conversation
    let isFrontmost: Bool
    /// Every pane of the grid draws while the todo is on screen, not only the frontmost one.
    let isOnScreen: Bool
    let toolbarRequest: Binding<ConversationToolbarRequest?>
    let onContinue: () -> Void
    @State private var loader: ConversationLoader

    init(todo: Todo, store: TodoHubStore, conversation: Conversation, hostList: HostList, isFrontmost: Bool,
         isOnScreen: Bool, toolbarRequest: Binding<ConversationToolbarRequest?>, onContinue: @escaping () -> Void) {
        self.todo = todo
        self.store = store
        self.conversation = conversation
        self.isFrontmost = isFrontmost
        self.isOnScreen = isOnScreen
        self.toolbarRequest = toolbarRequest
        self.onContinue = onContinue
        _loader = State(initialValue: ConversationLoader(
            todo: todo, dependencies: .live(store: store, hosts: { hostList.hosts })
        ))
    }

    private var current: Conversation { store.conversation(withKey: conversation.listKey) ?? conversation }

    var body: some View {
        VStack(spacing: 4) {
            ConversationPaneHeader(conversation: current, onContinue: onContinue)
                .padding(.horizontal, 6)
            ConversationFrame(todo: todo, loader: loader, store: store, placeholder: nil, onPopOut: nil,
                              isFrontmost: isFrontmost, sharesColumn: true, toolbarRequest: toolbarRequest,
                              pinnedConversationKey: conversation.listKey, isOnScreen: isOnScreen, onDeleted: {})
        }
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        // Attach once the tool has started (a Codex or Cursor id arrives a moment later).
        .task(id: "\(current.sessionId)|\(current.status.rawValue)") {
            guard loader.phase == .idle, ConversationSwitcherModel.paneCanAttach(current) else { return }
            loader.attachIfRunning(current)
        }
    }
}
#endif
