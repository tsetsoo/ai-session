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

    var body: some View {
        frame
            .onChange(of: hosts) { _, hosts in hostList.hosts = hosts }
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
