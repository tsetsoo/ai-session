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
    }

    var deleteTarget: Conversation?
    var failure: Failure?
    /// Todo ids whose conversation is being closed or deleted.
    private(set) var inFlight: Set<String> = []
    private(set) var showingCopied = false
    private var copiedTask: Task<Void, Never>?

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

    private func run(_ failureTitle: String, _ conversation: Conversation, hosts: [HostEntity],
                     _ body: @escaping (HostConnectionConfig) async throws -> Void) {
        let todoID = conversation.todoId
        inFlight.insert(todoID)
        Task {
            defer { inFlight.remove(todoID) }
            do {
                try await body(HostLookup.config(for: conversation.computer, in: hosts))
            } catch {
                failure = Failure(title: failureTitle, message: Self.message(for: error, computer: conversation.computer))
            }
        }
    }

    /// Failure copy for work on a computer, without SSH words: missing access points to
    /// Settings, and remote output is never shown raw. Hub errors keep the store's message.
    static func message(for error: Error, computer: Computer) -> String {
        let name = computer.name
        let setUp = "This device can't reach \(name) yet. Set up access in Settings."
        if error is HostLookup.Failure { return setUp }
        if error is RemoteConversations.ScriptMissing { return "\(name) needs the AI Session helpers." }
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
    /// The delete confirmation, failure alert and Copied toast for `actions`.
    func conversationActions(_ actions: ConversationRowActions, store: TodoHubStore, hosts: [HostEntity]) -> some View {
        modifier(ConversationActionsPresenter(actions: actions, store: store, hosts: hosts))
    }

    /// Swipes and context menu for a conversation row: leading Copy resume command; trailing
    /// Delete… and, while it runs, Close.
    func conversationRowMenu(_ conversation: Conversation, isRunning: Bool, actions: ConversationRowActions,
                             store: TodoHubStore, hosts: [HostEntity], open: (() -> Void)?) -> some View {
        modifier(ConversationRowMenu(conversation: conversation, isRunning: isRunning, actions: actions,
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
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
            .overlay(alignment: .top) {
                if actions.showingCopied {
                    CopiedToast().transition(.opacity)
                }
            }
    }
}

private struct ConversationRowMenu: ViewModifier {
    let conversation: Conversation
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
                MuteNotificationsButton(todoID: conversation.todoId)
                // Offline, the changing items are left out, like the swipes.
                if !store.isOffline {
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

/// "Mute Notifications" for a todo's alerts. Shown only once the notifier supports muting (the
/// push-notifications work); the local notifier doesn't. Unmute needs the muted state, which the
/// coordinator will provide.
struct MuteNotificationsButton: View {
    let todoID: String

    @Environment(AppModel.self) private var model

    var body: some View {
        if model.notifier.supportsMuting {
            Button {
                let notifier = model.notifier
                // The coordinator reports its own failures; there is nothing to show here.
                Task { try? await notifier.setMuted(todoId: todoID, true) }
            } label: {
                Label("Mute Notifications", systemImage: "bell.slash")
            }
        }
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
