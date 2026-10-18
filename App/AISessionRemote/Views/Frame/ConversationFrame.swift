import AISessionCore
import SwiftData
import SwiftUI

/// Shown in the frame's terminal area in place of the loader's state.
enum FramePlaceholder {
    /// The selection is settling before it attaches: just the terminal background, so arrowing
    /// through running conversations doesn't flash Start / Resume.
    case settling
    /// Waiting for the computer's tmux sessions to be listed before attaching.
    case checking(computer: String)
    /// The conversation is attached in its own window (Mac).
    case poppedOut(showWindow: () -> Void, bringBack: () -> Void)
}

extension EnvironmentValues {
    /// The frame fills its own window (the Mac pop-out), so the window's native title and
    /// subtitle name the todo and the frame doesn't repeat them in its toolbar.
    @Entry var frameOwnsWindow = false
}

/// A todo's conversation: a native header (title, section · computer · folder · tool, live
/// status pill, actions) around the terminal area. The header renders from local data at once;
/// the terminal area moves through the loader's phases on the terminal's own background.
struct ConversationFrame: View {
    let todo: Todo
    let loader: ConversationLoader
    let store: TodoHubStore
    let onDeleted: () -> Void
    /// `.settling` and `.checking` apply only while the loader is idle; `.poppedOut` always.
    private let placeholder: FramePlaceholder?
    /// ⧉ Open in New Window (Mac); nil hides it, as in the pop-out window itself.
    private let onPopOut: (() -> Void)?
    /// The detail column keeps other conversations mounted. Only the one on screen names
    /// itself in the window and takes the keyboard.
    private let isFrontmost: Bool
    /// Several frames share the detail column, so the column owns the window title. A phone
    /// screen and a pop-out window are the only frame in their navigation, and name themselves.
    private let sharesColumn: Bool
    private let makeTransport: (HostConnectionConfig, TerminalMode) -> any TerminalTransport

    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @Environment(\.frameOwnsWindow) private var ownsWindow
    /// Absent in previews.
    @Environment(AppModel.self) private var appModel: AppModel?
    @State private var terminal = TerminalHandle()
    @State private var showingCopied = false
    @State private var copiedTask: Task<Void, Never>?
    @State private var showingDeleteConfirmation = false
    @State private var failure: ActionFailure?
    @State private var sheet: FrameSheet?
    @State private var showingMemories = false
    /// Arms the key bar's Approve on a fresh `waiting`; typing disarms it.
    @State private var approveGate = ApproveGate()
    /// Opened while waiting: keyboard focus goes to the terminal once it connects.
    @State private var waitingFocus = WaitingFocus()

    init(
        todo: Todo,
        loader: ConversationLoader,
        store: TodoHubStore,
        placeholder: FramePlaceholder? = nil,
        onPopOut: (() -> Void)? = nil,
        isFrontmost: Bool = true,
        sharesColumn: Bool = false,
        onDeleted: @escaping () -> Void,
        makeTransport: @escaping (HostConnectionConfig, TerminalMode) -> any TerminalTransport = {
            SSHTerminalSession(config: $0, mode: $1)
        }
    ) {
        self.todo = todo
        self.loader = loader
        self.store = store
        self.placeholder = placeholder
        self.onPopOut = onPopOut
        self.isFrontmost = isFrontmost
        self.sharesColumn = sharesColumn
        self.onDeleted = onDeleted
        self.makeTransport = makeTransport
    }

    var body: some View {
        // `sharesColumn` is fixed for the life of the frame. The branch stays put, so the
        // terminal inside is not rebuilt when another conversation is selected.
        if sharesColumn {
            frame
        } else {
            frame
                .navigationTitle(todo.title)
                #if os(macOS)
                .navigationSubtitle(meta(includeFolder: true))
                #endif
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var frame: some View {
        terminalArea
        .onChange(of: liveStatus, initial: true) { _, status in
            if let status { approveGate.statusChanged(to: status) }
        }
        // Switching to a conversation that waits on you lands focus in its terminal; on the
        // Mac that takes it from the list. Other conversations keep the terminal's own
        // focus-after-connect.
        .onChange(of: readyTerminalID, initial: true) { _, id in
            waitingFocus.readyChanged(isReady: id != nil, status: liveStatus)
        }
        .onChange(of: terminal.connectionState) { _, state in
            guard state == .connected, waitingFocus.connected() else { return }
            focusTerminalWhenWaiting()
        }
        .onChange(of: isFrontmost) { _, front in
            // Coming back to a terminal that is already connected: focus it when it is waiting.
            // One that is still connecting focuses itself when it connects.
            guard front, terminal.connectionState == .connected else { return }
            waitingFocus.readyChanged(isReady: true, status: liveStatus)
            guard waitingFocus.connected() else { return }
            focusTerminalWhenWaiting()
        }
        .onChange(of: appModel?.terminalFocusRequest) { _, request in focusRequested(request) }
        .overlay(alignment: .top) {
            if isFrontmost && showingCopied {
                CopiedToast().transition(.opacity)
            }
        }
        .toolbar { if isFrontmost { frameToolbar } }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(
                get: { isFrontmost && showingDeleteConfirmation },
                set: { if !$0 { showingDeleteConfirmation = false } }
            ),
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
            isPresented: Binding(get: { isFrontmost && failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .sheet(
            item: Binding(get: { isFrontmost ? sheet : nil }, set: { sheet = $0 }),
            onDismiss: retryAfterSettings
        ) { sheet in
            sheetContent(sheet)
        }
        .modifier(MemoriesPresenter(
            isPresented: Binding(get: { isFrontmost && showingMemories }, set: { showingMemories = $0 }),
            todoID: todo.id, conversation: conversation, store: store
        ))
        // The conversation on screen is never alerted about, on any device.
        // Only the frame showing the terminal: a popped-out placeholder is not on screen,
        // and neither is a conversation kept attached behind the one on screen.
        .reportsVisibleConversation(todo.id, isActive: isFrontmost && !isPoppedOut)
    }

    // MARK: Terminal area

    @ViewBuilder
    private var terminalArea: some View {
        if let placeholder = activePlaceholder {
            placeholderState(placeholder)
        } else {
            phaseArea
        }
    }

    private var isPoppedOut: Bool {
        if case .poppedOut = placeholder { return true }
        return false
    }

    private var activePlaceholder: FramePlaceholder? {
        switch placeholder {
        case .poppedOut: placeholder
        case .settling, .checking: loader.phase == .idle ? placeholder : nil
        case nil: nil
        }
    }

    @ViewBuilder
    private func placeholderState(_ placeholder: FramePlaceholder) -> some View {
        switch placeholder {
        case .settling:
            onTerminalBackground(Color.clear)
        case let .checking(computer):
            onTerminalBackground(FrameStateBlock(showsProgress: true, title: "Connecting to \(computer)…"))
        case let .poppedOut(showWindow, bringBack):
            onTerminalBackground(FrameStateBlock(
                systemImage: Self.popOutSymbol,
                title: "Open in its own window",
                message: "Attached there, so this window doesn't fight it over the terminal size.",
                primary: FrameStateButton(title: "Show Window", action: showWindow),
                secondary: FrameStateButton(title: "Bring Back", action: bringBack)
            ))
        }
    }

    static let popOutSymbol = "macwindow.on.rectangle"

    @ViewBuilder
    private var phaseArea: some View {
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
                // Only while armed: otherwise every keystroke would write this @State.
                onUserInput: { if approveGate.isArmed { approveGate.userTyped() } },
                tool: conversation.tool,
                approveEnabled: approveGate.isEnabled(tool: conversation.tool),
                isFrontmost: isFrontmost,
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

    private func onTerminalBackground(_ content: some View) -> some View {
        content.modifier(OnTerminalBackground())
    }

    // MARK: Header

    @ToolbarContentBuilder
    private var frameToolbar: some ToolbarContent {
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
        // In the Mac split view the window title belongs to the list column, so the frame
        // names its todo at the leading edge of its own toolbar (not in a pop-out window,
        // whose own title already does).
        ToolbarItemGroup(placement: .primaryAction) {
            if !ownsWindow {
                VStack(alignment: .leading, spacing: 1) {
                    Text(todo.title)
                        .font(.headline)
                    Text(meta(includeFolder: true))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
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
            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: Self.popOutSymbol)
                }
                .help("Open in New Window (⇧⌘O)")
                .accessibilityLabel("Open in New Window")
            }
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

    /// The hub's status for this todo's conversation, as last heard.
    private var liveStatus: ConversationStatus? {
        store.conversations[todo.id]?.status ?? todo.conversationStatus
    }

    /// Live status; nil (no pill) when the todo has never had a conversation.
    private var displayStatus: ConversationDisplayStatus? {
        guard store.conversations[todo.id] != nil || todo.conversationStatus != nil else { return nil }
        return ConversationDisplayStatus(
            store.conversations[todo.id]?.status ?? todo.conversationStatus ?? .unknown,
            tmuxAlive: nil
        )
    }

    private func meta(includeFolder: Bool) -> String {
        Self.subtitle(todo: todo, store: store, includeFolder: includeFolder)
    }

    /// `section · computer · folder · tool`, from the conversation or else the section's
    /// computer. The folder is middle-truncated. The detail column uses the same line for the
    /// window subtitle while several frames stay mounted.
    static func subtitle(todo: Todo, store: TodoHubStore, includeFolder: Bool) -> String {
        let target: (computer: String, folder: String, tool: String)? = {
            if let conversation = store.conversations[todo.id] {
                return (conversation.computer.name, conversation.cwd, conversation.tool)
            }
            if let mapping = store.sectionComputers[todo.section] {
                return (mapping.computer.name, mapping.cwd, mapping.tool)
            }
            return nil
        }()
        guard let target else { return "\(todo.section.rawValue) · no computer" }
        var parts = [todo.section.rawValue, target.computer]
        if includeFolder {
            parts.append(middleTruncated(target.folder))
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

    /// The terminal surface's identity while ready: a new one connects afresh.
    private var readyTerminalID: String? {
        readyConversation.map { "\($0.id)|\($0.hostID)" }
    }

    /// After the surface's own focus-after-connect and whatever the list did with the click or
    /// key that selected this conversation.
    private func focusTerminalWhenWaiting() {
        #if DEBUG
        // Screenshots: `-uiDemoKeyboard down` keeps the soft keyboard away.
        if DemoFixtures.isEnabled, DemoFixtures.value(after: "-uiDemoKeyboard") == "down" { return }
        #endif
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            // Not from under the ⌘K palette's search field; closing it brings focus back.
            guard appModel?.allowsTerminalAutoFocus ?? true else { return }
            terminal.focus()
        }
    }

    /// The ⌘K palette closed (or went to this conversation): keyboard focus back in the
    /// terminal when it is already connected. One that connects later focuses itself.
    private func focusRequested(_ request: AppModel.TerminalFocusRequest?) {
        guard let request, request.todoID == todo.id, !isPoppedOut,
              terminal.connectionState == .connected else { return }
        Task {
            // After the palette's field has left the window.
            try? await Task.sleep(for: .milliseconds(50))
            terminal.focus()
        }
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

