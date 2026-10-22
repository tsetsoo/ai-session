import AISessionCore
import SwiftUI

/// Close, Delete… and Copy resume command for conversations shown in a list. Each list owns
/// one and attaches `.conversationActions(_:store:hosts:)`, which shows the delete
/// confirmation, failures and the Copied toast.
@MainActor
@Observable
final class ConversationRowActions {
    struct Failure {
        let title: String
        let message: String
        /// A hub computer this device has no access to: the alert offers Set Up Access.
        var setUpAccess: Computer?
    }

    var deleteTarget: Conversation?
    var failure: Failure?
    /// Conversation ids being closed or deleted.
    private(set) var inFlight: Set<String> = []
    private(set) var showingCopied = false
    private var copiedTask: Task<Void, Never>?
    /// Just muted: the toast with Undo shows for this todo.
    private(set) var mutedTodoID: String?
    private var mutedTask: Task<Void, Never>?

    /// Ends the conversation on its computer; it stays resumable.
    func close(_ conversation: Conversation, store: TodoHubStore, hosts: [HostEntity]) {
        run("Couldn't Close Conversation", conversation, hosts: hosts) { config in
            try await store.closeConversation(conversation, config: config)
        }
    }

    func delete(_ conversation: Conversation, store: TodoHubStore, hosts: [HostEntity]) {
        run("Couldn't Delete Conversation", conversation, hosts: hosts) { config in
            try await store.deleteConversation(conversation, config: config)
        }
    }

    func copyResumeCommand(_ conversation: Conversation) {
        PlatformSupport.pasteboardString = ResumeCommand.string(for: conversation)
        copiedTask?.cancel()
        withAnimation { showingCopied = true }
        copiedTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showingCopied = false }
        }
    }

    /// Mutes (or, from the toast's Undo, unmutes) a todo's notifications on the hub. Success
    /// shows the Muted toast; a failure the alert.
    func setMuted(todoID: String, _ muted: Bool) {
        mutedTask?.cancel()
        withAnimation { mutedTodoID = nil }
        Task {
            do {
                try await NotificationCenterCoordinator.shared.setMuted(todoId: todoID, muted)
            } catch {
                failure = Failure(title: muted ? "Couldn't Mute Notifications" : "Couldn't Unmute Notifications",
                                  message: TodoHubStore.message(for: error))
                return
            }
            guard muted else { return }
            withAnimation { mutedTodoID = todoID }
            mutedTask = Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation { mutedTodoID = nil }
            }
        }
    }

    private func run(_ failureTitle: String, _ conversation: Conversation, hosts: [HostEntity],
                     _ body: @escaping (HostConnectionConfig) async throws -> Void) {
        let conversationID = conversation.listKey
        inFlight.insert(conversationID)
        Task {
            defer { inFlight.remove(conversationID) }
            do {
                try await body(HostLookup.config(for: conversation.computer, in: hosts))
            } catch {
                failure = Failure(title: failureTitle, message: Self.message(for: error, computer: conversation.computer),
                                  setUpAccess: Self.computerToSetUp(after: error))
            }
        }
    }

    /// Failure copy for work on a computer, without SSH words: missing access points to the
    /// alert's Set Up Access (no host) or Settings (a key or sign-in problem), and remote
    /// output is never shown raw. Hub errors keep the store's message.
    static func message(for error: Error, computer: Computer) -> String {
        let name = computer.name
        let setUp = "This device can't reach \(name) yet. Set up access in Settings."
        // The alert's Set Up Access button opens the host editor for this one.
        if computerToSetUp(after: error) != nil {
            return "This device can't reach \(name) yet. Set up access to \(name) on this device."
        }
        if error is HostLookup.Failure { return setUp }
        if error is RemoteConversations.ScriptMissing { return "\(name) needs the AI Session helpers." }
        if error is RemoteConversations.NoTranscript { return "This conversation has no transcript on \(name)." }
        if error is RemoteConversations.UnreadableList { return "Couldn't read the conversations on \(name)." }
        switch error as? SSHRemoteError {
        case .unreachable?:
            return "Can't reach \(name). Check it's awake and on Tailscale."
        case .authenticationFailed?:
            return setUp
        case let .binaryMissing(binary)?:
            guard let tool = toolName(forBinary: binary) else { return "Something \(name) needs isn't installed there." }
            return "\(tool) isn't installed on \(name)."
        case .tmuxMissing?:
            return "Something \(name) needs isn't installed there."
        case .commandFailed?:
            return "\(name) couldn't finish that. Try again."
        case nil:
            return TodoHubStore.message(for: error)
        }
    }

    /// The computer to set up access to, when the failure was having none.
    static func computerToSetUp(after error: Error) -> Computer? {
        if case let .noHost(computer)? = error as? HostLookup.Failure { return computer }
        return nil
    }

    private static func toolName(forBinary binary: String) -> String? {
        switch binary {
        case "claude": "Claude"
        case "codex": "Codex"
        case "agent", "cursor-agent": "Cursor"
        default: nil
        }
    }
}

extension View {
    /// The store's modal error: a todo change or a first load that failed. Each shell attaches
    /// it once, so it shows whichever list is on screen.
    func todoStoreErrorAlert(_ store: TodoHubStore) -> some View {
        alert(
            "Todos",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    /// "Delete “title”?" before `target` goes. Set the binding to ask; failures go to the
    /// store's Todos alert like other todo changes.
    func todoDeleteConfirmation(_ target: Binding<Todo?>, store: TodoHubStore) -> some View {
        confirmationDialog(
            target.wrappedValue.map { "Delete “\($0.title)”?" } ?? "",
            isPresented: Binding(get: { target.wrappedValue != nil }, set: { if !$0 { target.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: target.wrappedValue
        ) { todo in
            Button("Delete Todo", role: .destructive) {
                Task { await store.delete(todo) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { todo in
            Text(RowText.todoDeleteMessage(conversations: store.conversations(forTodo: todo.id)))
        }
    }

    /// The delete confirmation, failure alert and Copied toast for `actions`.
    func conversationActions(_ actions: ConversationRowActions, store: TodoHubStore, hosts: [HostEntity]) -> some View {
        modifier(ConversationActionsPresenter(actions: actions, store: store, hosts: hosts))
    }

    /// Swipes and context menu for a conversation row: leading Copy resume command and its
    /// todo's Done; trailing Delete… and, while it runs, Close.
    func conversationRowMenu(_ conversation: Conversation, todo: Todo?, isRunning: Bool,
                             actions: ConversationRowActions, store: TodoHubStore, hosts: [HostEntity],
                             open: (() -> Void)?) -> some View {
        modifier(ConversationRowMenu(conversation: conversation, todo: todo, isRunning: isRunning, actions: actions,
                                     store: store, hosts: hosts, open: open))
    }

    /// Makes the whole row open something while buttons inside it stay tappable. Without an
    /// action the row is left alone, so a selectable list's own click selection still works.
    @ViewBuilder
    func rowTap(_ action: (() -> Void)?) -> some View {
        if let action {
            contentShape(Rectangle())
                .onTapGesture(perform: action)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            self
        }
    }
}

private struct ConversationActionsPresenter: ViewModifier {
    @Bindable var actions: ConversationRowActions
    let store: TodoHubStore
    let hosts: [HostEntity]
    @State private var setUpPrefill: HostEditorPrefill?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete this conversation?",
                isPresented: Binding(get: { actions.deleteTarget != nil }, set: { if !$0 { actions.deleteTarget = nil } }),
                titleVisibility: .visible,
                presenting: actions.deleteTarget
            ) { conversation in
                Button("Delete Conversation", role: .destructive) {
                    actions.delete(conversation, store: store, hosts: hosts)
                }
                Button("Cancel", role: .cancel) {}
            } message: { conversation in
                Text(conversation.deleteConfirmationMessage)
            }
            .alert(
                actions.failure?.title ?? "",
                isPresented: Binding(get: { actions.failure != nil }, set: { if !$0 { actions.failure = nil } }),
                presenting: actions.failure
            ) { failure in
                if let computer = failure.setUpAccess {
                    Button("Set Up Access") { setUpPrefill = HostEditorPrefill(computer: computer) }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { failure in
                Text(failure.message)
            }
            .sheet(item: $setUpPrefill) { prefill in
                // Create mode: the host and its key are saved together, and Cancel leaves nothing.
                HostEditorView(prefill: prefill)
            }
            .overlay(alignment: .top) {
                if actions.showingCopied {
                    CopiedToast().transition(.opacity)
                } else if let todoID = actions.mutedTodoID {
                    MutedToast { actions.setMuted(todoID: todoID, false) }
                        .transition(.opacity)
                }
            }
    }
}

private struct ConversationRowMenu: ViewModifier {
    let conversation: Conversation
    let todo: Todo?
    let isRunning: Bool
    let actions: ConversationRowActions
    let store: TodoHubStore
    let hosts: [HostEntity]
    let open: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    actions.copyResumeCommand(conversation)
                } label: {
                    Label("Copy Resume Command", systemImage: "doc.on.doc")
                }
                .tint(DS.accentSolid)
                if let todo, !store.isOffline {
                    Button {
                        Task { await store.toggle(todo) }
                    } label: {
                        Label(todo.completed ? "Undo" : "Done",
                              systemImage: todo.completed ? "arrow.uturn.backward" : "checkmark")
                    }
                    .tint(.green)
                }
            }
            // Offline, the changing swipes are left out rather than disabled.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !store.isOffline {
                    Button {
                        actions.deleteTarget = conversation
                    } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                    .tint(.red)
                    if isRunning {
                        Button {
                            actions.close(conversation, store: store, hosts: hosts)
                        } label: {
                            Label("Close", systemImage: "xmark.circle")
                        }
                        .tint(.gray)
                    }
                }
            }
            .contextMenu {
                if let open {
                    Button(action: open) {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                }
                Button {
                    actions.copyResumeCommand(conversation)
                } label: {
                    Label("Copy Resume Command", systemImage: "doc.on.doc")
                }
                MuteNotificationsButton(todoID: conversation.todoId, actions: actions)
                // Offline, the changing items are left out, like the swipes.
                if !store.isOffline {
                    if let todo {
                        Button {
                            Task { await store.toggle(todo) }
                        } label: {
                            Label(todo.completed ? "Mark Todo Not Done" : "Mark Todo Done",
                                  systemImage: todo.completed ? "arrow.uturn.backward" : "checkmark.circle")
                        }
                        Divider()
                    }
                    Button {
                        actions.close(conversation, store: store, hosts: hosts)
                    } label: {
                        Label("Close Conversation", systemImage: "xmark.circle")
                    }
                    .disabled(!isRunning)
                    Button(role: .destructive) {
                        actions.deleteTarget = conversation
                    } label: {
                        Label("Delete Conversation…", systemImage: "trash")
                    }
                }
            }
    }
}

/// "Mute Notifications" for a todo's alerts (stored on the todo server, so every device stays
/// quiet). There is no Unmute item: the coordinator doesn't expose the muted state. The
/// "Muted" toast offers Undo, and mutes are listed and lifted in Settings → Notifications.
/// Shown while notifications are on.
struct MuteNotificationsButton: View {
    let todoID: String
    /// Shows the Muted toast or the failure.
    let actions: ConversationRowActions

    @AppStorage(NotificationCenterCoordinator.enabledKey) private var notificationsOn = false

    var body: some View {
        if notificationsOn {
            Button {
                actions.setMuted(todoID: todoID, true)
            } label: {
                Label("Mute Notifications", systemImage: "bell.slash")
            }
        }
    }
}

/// "Notifications muted" with Undo, after Mute Notifications, styled like `CopiedToast`.
private struct MutedToast: View {
    let undo: () -> Void

    var body: some View {
        HStack(spacing: DS.spacing.m) {
            Label("Notifications muted", systemImage: "bell.slash")
                .font(.callout.weight(.semibold))
            Button("Undo", action: undo)
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold))
                .tint(DS.accent)
        }
        .padding(.horizontal, DS.spacing.l)
        .padding(.vertical, DS.spacing.s)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, DS.spacing.m)
    }
}

/// The top-of-list sync problem: offline (with Retry) or a background issue such as a
/// rejected token.
struct ListStatusBanner: View {
    let store: TodoHubStore

    @Environment(\.openAppSettings) private var openSettings

    var body: some View {
        if store.isOffline {
            Section {
                HStack(spacing: DS.spacing.m) {
                    Label(offlineText, systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") { Task { await store.refresh() } }
                        .buttonStyle(.borderless)
                        .tint(DS.accent)
                }
            }
        } else if let issue = store.backgroundIssue {
            Section {
                HStack(spacing: DS.spacing.m) {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if store.tokenRejected, let openSettings {
                        Button("Open Settings") { openSettings(.server) }
                            .buttonStyle(.borderless)
                            .tint(DS.accent)
                    }
                }
            }
        }
    }

    private var offlineText: String {
        guard let cachedAt = store.cachedAt else { return "Offline · showing saved todos" }
        return "Offline · showing todos from \(SyncLine.ago(cachedAt, now: .now))"
    }
}

extension HostEditorPrefill {
    /// "Set Up" for a hub computer: the host editor in create mode with its address filled in.
    init(computer: Computer) {
        self.init(displayName: computer.name, hostname: computer.hostname, port: computer.port,
                  username: computer.username)
    }
}
