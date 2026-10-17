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

/// The conversation frame for a todo.
///
/// - `.start`: a tap on iPhone is an explicit open, so the loader starts (or resumes) the
///   conversation as soon as the frame appears.
/// - `.onRequest`: a selection on the Mac never starts anything. The shell's
///   `SelectionAttacher` sends `.attach` for a running conversation, and ⏎ or a double-click
///   sends `.start`; until then the frame shows Start / Resume.
struct TodoConversationScreen: View {
    enum OnAppear {
        case start, onRequest
    }

    let todo: Todo
    let store: TodoHubStore
    let onAppear: OnAppear
    @Binding var request: FrameRequest?
    /// Drawn in the terminal area instead of the loader's state (see `FramePlaceholder`).
    let placeholder: FramePlaceholder?
    /// Popped out into its own window: this frame holds no terminal and ignores requests.
    let isSuspended: Bool
    let onPopOut: (() -> Void)?
    let onDeleted: () -> Void

    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var hostList: HostList
    @State private var loader: ConversationLoader
    /// The `.start` open happens once per screen: coming back to it (another tab and back)
    /// after Close must not resume the conversation by itself.
    @State private var didOpen = false

    init(todo: Todo, store: TodoHubStore, onAppear: OnAppear = .start, request: Binding<FrameRequest?> = .constant(nil),
         placeholder: FramePlaceholder? = nil, isSuspended: Bool = false, onPopOut: (() -> Void)? = nil,
         onDeleted: @escaping () -> Void) {
        self.todo = todo
        self.store = store
        self.onAppear = onAppear
        _request = request
        self.placeholder = placeholder
        self.isSuspended = isSuspended
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
            .onChange(of: isSuspended) { _, suspended in
                // The pop-out window attaches on its own; don't stay attached here too.
                if suspended { loader.reset() }
            }
            .task {
                hostList.hosts = hosts
                guard onAppear == .start, !didOpen, loader.phase == .idle else { return }
                didOpen = true
                await loader.start()
            }
    }

    private func handle(_ request: FrameRequest?) {
        guard let request, request.todoID == todo.id else { return }
        self.request = nil
        hostList.hosts = hosts
        switch request.kind {
        case .attach:
            // Only into an idle frame: an explicit start or a problem card stays as it is.
            guard !isSuspended, loader.phase == .idle else { return }
            loader.attachIfRunning(store.conversations[todo.id])
        case .detach:
            guard loader.phase != .idle, loader.phase != .preparing else { return }
            loader.reset()
        case .start:
            // An open terminal stays as it is; a problem retries.
            guard !isSuspended, loader.phase == .idle || isProblem else { return }
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
                                     onPopOut: onPopOut, onDeleted: onDeleted,
                                     makeTransport: { _, _ in DemoTransport() })
        }
        #endif
        return ConversationFrame(todo: todo, loader: loader, store: store, placeholder: placeholder,
                                 onPopOut: onPopOut, onDeleted: onDeleted)
    }
}

/// The current saved hosts, read by the loader on every resolve (a host added from the frame's
/// Set Up Access then counts on retry).
@MainActor
private final class HostList {
    var hosts: [HostEntity] = []
}
