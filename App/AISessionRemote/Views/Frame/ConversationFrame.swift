import AISessionCore
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A todo's conversation: a native header (title, section · computer · folder · tool, live
/// status pill, actions) around the terminal area. The header renders from local data at once;
/// the terminal area moves through the loader's phases on the terminal's own background.
struct ConversationFrame: View {
    let todo: Todo
    let loader: ConversationLoader
    let store: TodoHubStore
    let onDeleted: () -> Void
    private let makeTransport: (HostConnectionConfig, TerminalMode) -> any TerminalTransport

    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("terminal.theme") private var themeRaw = TerminalTheme.system.rawValue
    @State private var terminal = TerminalHandle()
    @State private var showingCopied = false
    @State private var copiedTask: Task<Void, Never>?
    @State private var showingDeleteConfirmation = false
    @State private var failure: ActionFailure?
    @State private var sheet: FrameSheet?
    @State private var showingMemories = false
    @State private var keyboardVisible = false

    init(
        todo: Todo,
        loader: ConversationLoader,
        store: TodoHubStore,
        onDeleted: @escaping () -> Void,
        makeTransport: @escaping (HostConnectionConfig, TerminalMode) -> any TerminalTransport = {
            SSHTerminalSession(config: $0, mode: $1)
        }
    ) {
        self.todo = todo
        self.loader = loader
        self.store = store
        self.onDeleted = onDeleted
        self.makeTransport = makeTransport
    }

    var body: some View {
        ZStack {
            terminalArea
            #if os(iOS)
            // Until the key bar replaces it (PR 4), the same soft keys as the plain terminal.
            if isConnected && !keyboardVisible {
                VStack {
                    Spacer()
                    SoftKeyBar { key in
                        switch key {
                        case .ctrlC: terminal.send([0x03])
                        case .tab: terminal.send([0x09])
                        case .esc: terminal.send([0x1B])
                        case .paste: terminal.paste()
                        }
                    }
                }
                .transition(.move(edge: .bottom))
            }
            #endif
        }
        .overlay(alignment: .top) {
            if showingCopied {
                CopiedToast().transition(.opacity)
            }
        }
        .navigationTitle(todo.title)
        #if os(macOS)
        .navigationSubtitle(meta(includeFolder: true))
        #endif
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Conversation", role: .destructive) { deleteConversation() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let conversation {
                Text(conversation.deleteConfirmationMessage)
            }
        }
        .alert(
            failure?.title ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .sheet(item: $sheet, onDismiss: retryAfterSettings) { sheet in
            sheetContent(sheet)
        }
        .modifier(MemoriesPresenter(isPresented: $showingMemories, todoID: todo.id, conversation: conversation,
                                    store: store))
        // The conversation on screen is never alerted about, on any device.
        .reportsVisibleConversation(todo.id)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        #endif
    }

    // MARK: Terminal area

    @ViewBuilder
    private var terminalArea: some View {
        switch loader.phase {
        case .idle:
            onTerminalBackground(idleState)
        case .preparing:
            onTerminalBackground(FrameStateBlock(showsProgress: true, title: preparingTitle))
        case let .ready(open):
            let conversation = open.conversation
            TerminalSurface(
                config: open.config,
                mode: .attach(TmuxCommandBuilder.openTodoConversation(
                    tmuxName: conversation.tmuxName,
                    cwd: conversation.cwd,
                    sessionId: conversation.sessionId,
                    tool: conversation.tool
                )),
                hostName: conversation.computer.name,
                handle: terminal,
                onConnectionFailed: { error in
                    let noted = SSHSignInRecord.problem(hostID: open.config.hostID)
                    loader.connectionFailed(.classify(error, signInProblem: noted))
                },
                onEnded: { exitStatus in loader.ended(exitStatus: exitStatus) },
                makeTransport: makeTransport
            )
            // Re-entering `.ready` for the same conversation and host must not reconnect.
            .id("\(open.id)|\(open.hostID)")
        case let .problem(problem):
            onTerminalBackground(FrameStateView(
                problem: problem,
                actions: actions,
                tool: conversation?.tool,
                resumeCommand: conversation.map(ResumeCommand.string(for:))
            ))
        }
    }

    private var idleState: some View {
        let target = startTarget
        let tool = RemoteConversationPicker.toolName(target?.tool ?? "claude")
        let resumes = conversation != nil
        return FrameStateBlock(
            systemImage: target?.tool == "codex" ? "chevron.left.forwardslash.chevron.right" : "sparkle",
            iconTint: DS.accent,
            title: resumes ? "Resume" : "No conversation yet",
            message: target.map { target in
                resumes
                    ? "Picks the \(tool) conversation back up in \(target.folder) on \(target.computer)."
                    : "Starts \(tool) in \(target.folder) on \(target.computer)."
            },
            primary: FrameStateButton(title: Self.startTitle) {
                Task { await loader.start() }
            }
        )
    }

    private static var startTitle: String {
        #if os(macOS)
        "Start Conversation ⏎"
        #else
        "Start Conversation"
        #endif
    }

    private var preparingTitle: String {
        guard let computer = startTarget?.computer else { return "Starting conversation…" }
        return "Starting conversation on \(computer)…"
    }

    /// Drawn on the terminal background, in the terminal's own light/dark scheme so system text
    /// colours stay legible whatever the app's appearance.
    private func onTerminalBackground(_ content: some View) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(palette.background))
            .environment(\.colorScheme, palette == .dark ? .dark : .light)
    }

    private var palette: TerminalPalette {
        TerminalAppearance.palette(theme: TerminalTheme(rawValue: themeRaw) ?? .system, colorScheme: colorScheme)
    }

    // MARK: Header

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(todo.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(meta(includeFolder: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let displayStatus {
                StatusBadge(displayStatus, style: .pill)
            }
            menu(onCopyResume: copyResumeCommand)
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            if let displayStatus {
                StatusBadge(displayStatus, style: .pill)
                    .padding(.horizontal, DS.spacing.xs)
            }
            Button(action: copyResumeCommand) {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy Resume Command")
            .accessibilityLabel("Copy Resume Command")
            .disabled(conversation == nil)
            menu(onCopyResume: nil)
        }
        #endif
    }

    private func menu(onCopyResume: (() -> Void)?) -> some View {
        ConversationMenu(
            hasConversation: conversation != nil,
            canChange: conversation != nil && !store.isOffline,
            isReady: readyConversation != nil,
            isConnected: isConnected,
            onCopyResume: onCopyResume,
            onMemories: { showingMemories = true },
            onClose: closeConversation,
            onDelete: { showingDeleteConfirmation = true },
            terminal: terminal
        )
    }

    /// Live status; nil (no pill) when the todo has never had a conversation.
    private var displayStatus: ConversationDisplayStatus? {
        guard store.conversations[todo.id] != nil || todo.conversationStatus != nil else { return nil }
        return ConversationDisplayStatus(
            store.conversations[todo.id]?.status ?? todo.conversationStatus ?? .unknown,
            tmuxAlive: nil
        )
    }

    /// `section · computer · folder · tool`, from the conversation or else the section's
    /// computer. The folder is middle-truncated.
    private func meta(includeFolder: Bool) -> String {
        guard let target = startTarget else { return "\(todo.section.rawValue) · no computer" }
        var parts = [todo.section.rawValue, target.computer]
        if includeFolder {
            parts.append(Self.middleTruncated(target.folder))
        }
        parts.append(RemoteConversationPicker.toolName(target.tool))
        return parts.joined(separator: " · ")
    }

    private static func middleTruncated(_ path: String, limit: Int = 40) -> String {
        guard path.count > limit else { return path }
        let head = (limit - 1) / 2
        return "\(path.prefix(head))…\(path.suffix(limit - 1 - head))"
    }

    // MARK: Data

    private var readyConversation: OpenTodoConversation? {
        if case let .ready(open) = loader.phase { return open }
        return nil
    }

    /// A live terminal on screen (the handle can lag behind a phase change).
    private var isConnected: Bool {
        readyConversation != nil && terminal.isConnected
    }

    private var conversation: Conversation? {
        store.conversations[todo.id] ?? readyConversation?.conversation
    }

    /// Where the conversation runs (or would start): the linked one, else the section's computer.
    private var startTarget: (computer: String, folder: String, tool: String)? {
        if let conversation {
            return (conversation.computer.name, conversation.cwd, conversation.tool)
        }
        if let mapping = store.sectionComputers[todo.section] {
            return (mapping.computer.name, mapping.cwd, mapping.tool)
        }
        return nil
    }

    // MARK: Actions

    private var actions: FrameActions {
        FrameActions(
            openSettings: openSettings,
            setUpAccess: { computer in
                sheet = .hostEditor(HostEditorPrefill(
                    displayName: computer.name,
                    hostname: computer.hostname,
                    port: computer.port,
                    username: computer.username
                ))
            },
            retry: { Task { await loader.start() } },
            copy: copy,
            unlink: unlinkConversation
        )
    }

    private func openSettings(_ destination: SettingsDestination) {
        // "Change Folder" doesn't know the section; it is this todo's.
        sheet = .settings(destination == .sections(nil) ? .sections(todo.section) : destination)
    }

    /// A settings sheet closed while a problem shows: try again with what was just fixed.
    private func retryAfterSettings() {
        guard case .problem = loader.phase else { return }
        Task { await loader.start() }
    }

    private func copyResumeCommand() {
        guard let conversation else { return }
        copy(ResumeCommand.string(for: conversation))
    }

    private func copy(_ text: String) {
        PlatformSupport.pasteboardString = text
        copiedTask?.cancel()
        withAnimation { showingCopied = true }
        copiedTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showingCopied = false }
        }
    }

    /// Ends tmux and keeps the conversation resumable (the old "Kill Session").
    private func closeConversation() {
        perform("Couldn't Close Conversation") { conversation, config in
            try await store.closeConversation(conversation, config: config)
            loader.reset()
        }
    }

    private func deleteConversation() {
        perform("Couldn't Delete Conversation") { conversation, config in
            try await store.deleteConversation(conversation, config: config)
            onDeleted()
        }
    }

    /// The conversation is gone from the computer: drop the link so the todo can start afresh.
    private func unlinkConversation() {
        perform("Couldn't Unlink Conversation") { conversation, config in
            try await store.deleteConversation(conversation, config: config)
            loader.reset()
        }
    }

    /// Runs a conversation action over SSH: the open terminal's config, else the matching host's.
    private func perform(
        _ failureTitle: String,
        _ body: @escaping (Conversation, HostConnectionConfig) async throws -> Void
    ) {
        guard let conversation else { return }
        let openConfig = readyConversation?.config
        Task {
            do {
                let config = try openConfig ?? HostLookup.config(for: conversation.computer, in: hosts)
                try await body(conversation, config)
            } catch {
                // Worded like the lists' actions: no SSH words, no raw remote output.
                failure = ActionFailure(
                    title: failureTitle,
                    message: ConversationRowActions.message(for: error, computer: conversation.computer)
                )
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: FrameSheet) -> some View {
        switch sheet {
        case let .settings(destination):
            SettingsView(initial: destination)
        case let .hostEditor(prefill):
            // Create mode: the host and its key are saved together, and Cancel leaves nothing.
            HostEditorView(prefill: prefill)
        }
    }
}

private struct ActionFailure {
    let title: String
    let message: String
}

private enum FrameSheet: Identifiable {
    case settings(SettingsDestination)
    case hostEditor(HostEditorPrefill)

    var id: String {
        switch self {
        case let .settings(destination): "settings-\(destination)"
        case let .hostEditor(prefill): "host-\(prefill.id)"
        }
    }
}

