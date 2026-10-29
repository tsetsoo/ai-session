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

/// A todo's conversation: a native header (title, section · computer · folder, live
/// status pill, actions) around the terminal area. The tool is a band on the terminal.
/// The header renders from local data at once; the terminal area moves through the loader's
/// phases on the terminal's own background.
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
    /// Several frames share the detail column, so the column owns the window title and the
    /// toolbar. A phone screen and a pop-out window are the only frame in their navigation.
    private let sharesColumn: Bool
    private let makeTransport: (HostConnectionConfig, TerminalMode) -> any TerminalTransport
    @Binding private var toolbarRequest: ConversationToolbarRequest?

    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @Environment(\.frameOwnsWindow) private var ownsWindow
    /// Absent in previews.
    @Environment(AppModel.self) private var appModel: AppModel?
    @State private var terminal = TerminalHandle()
    @State private var copied = TransientValue<Bool>(for: .toast)
    @State private var showingDeleteConfirmation = false
    @State private var renameTarget: Todo?
    @State private var showingCloseConfirmation = false
    @State private var failure: ActionFailure?
    @State private var sheet: FrameSheet?
    @State private var showingMemories = false
    /// Arms the key bar's Approve on a fresh `waiting`; typing disarms it.
    @State private var approveGate = ApproveGate()
    /// Opened while waiting: keyboard focus goes to the terminal once it connects.
    @State private var waitingFocus = WaitingFocus()
    /// The tool step. Empty until the frame appears, then the device's last tool, or Claude.
    @AppStorage(ConversationStart.storageKey) private var lastStartedTool = ""
    @State private var toolChoice = ""
    @State private var isStarting = false
    @State private var toolError: String?
    /// The start state's own pick of servers; until there is one, the defaults show.
    @State private var serverChoice: [String]?
    @State private var hasServerChoice = false
    /// "Servers…": the conversation whose checklist is open, then the one waiting on a restart.
    @State private var serversTarget: Conversation?
    @State private var restartTarget: Conversation?
    /// How the conversation just created should attach, and the text to type once it connects.
    @State private var duplicateLaunch: DuplicateLaunch?
    @State private var summaryText = ""
    @State private var summaryContext: DuplicateSummaryContext?
    @State private var isDuplicating = false
    /// Typing a duplicate's hand-off once the new tool takes pastes. Cancelled when the frame goes.
    @State private var handoffTask: Task<Void, Never>?
    #if os(iOS)
    @AppStorage("conversation.phoneChat") private var showsChat = true
    #endif

    init(
        todo: Todo,
        loader: ConversationLoader,
        store: TodoHubStore,
        placeholder: FramePlaceholder? = nil,
        onPopOut: (() -> Void)? = nil,
        isFrontmost: Bool = true,
        sharesColumn: Bool = false,
        toolbarRequest: Binding<ConversationToolbarRequest?> = .constant(nil),
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
        self._toolbarRequest = toolbarRequest
        self.onDeleted = onDeleted
        self.makeTransport = makeTransport
    }

    var body: some View {
        // `sharesColumn` is fixed for the life of the frame. The branch stays put, so the
        // terminal inside is not rebuilt when another conversation is selected.
        // Shared frames publish no toolbar: the column owns the one window toolbar.
        if ConversationToolbar.framePublishesToolbar(sharesColumn: sharesColumn) {
            frame
                .navigationTitle(todo.title)
                #if os(macOS)
                .navigationSubtitle(meta(includeFolder: true))
                #endif
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { frameToolbar }
        } else {
            frame
                .preference(key: ConversationTerminalStateKey.self, value: terminalState)
                .onChange(of: toolbarRequest, initial: true) { _, request in
                    guard let command = ConversationToolbar.commandToRun(
                        pending: request, todoID: todo.id, isFrontmost: isFrontmost
                    ) else { return }
                    toolbarRequest = nil
                    performToolbar(command)
                }
        }
    }

    private var terminalState: ConversationTerminalState? {
        guard isFrontmost else { return nil }
        return ConversationTerminalState(
            todoID: todo.id,
            isReady: readyConversation != nil,
            isConnected: isConnected,
            isDuplicating: isDuplicating
        )
    }

    private var frame: some View {
        serversPresentation(frameContent)
    }

    private var frameContent: some View {
        terminalArea
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let tool = chromeTool {
                    ToolBand(tool: tool)
                }
                limitsBar
            }
        }
        .overlay(alignment: .leading) {
            if let tool = chromeTool {
                Rectangle()
                    .fill(AppTheme.color(for: AITool(rawValue: tool)))
                    .frame(width: 4)
                    .modifier(TerminalColorScheme())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: liveStatus, initial: true) { _, status in
            if let status { approveGate.statusChanged(to: status) }
        }
        // Switching to a conversation that waits on you lands focus in its terminal; on the
        // Mac that takes it from the list. Other conversations keep the terminal's own
        // focus-after-connect.
        .onChange(of: readyTerminalID, initial: true) { _, id in
            waitingFocus.readyChanged(isReady: id != nil, status: liveStatus)
        }
        .onDisappear { handoffTask?.cancel() }
        #if os(iOS)
        .onChange(of: showsChat) { _, chat in
            if !chat, isFrontmost, terminal.isConnected { reviewOpenedConversation() }
        }
        #endif
        .onChange(of: terminal.connectionState) { _, state in
            if state == .connected { deliverDuplicateText() }
            if state == .connected, isFrontmost { reviewOpenedConversation() }
            guard state == .connected, waitingFocus.connected() else { return }
            focusTerminalWhenWaiting()
        }
        .onChange(of: isFrontmost) { _, front in
            if front, terminal.isConnected { reviewOpenedConversation() }
            // Coming back to a terminal that is already connected: focus it when it is waiting.
            // One that is still connecting focuses itself when it connects.
            guard front, terminal.connectionState == .connected else { return }
            waitingFocus.readyChanged(isReady: true, status: liveStatus)
            guard waitingFocus.connected() else { return }
            focusTerminalWhenWaiting()
        }
        .onChange(of: appModel?.terminalFocusRequest) { _, request in focusRequested(request) }
        .overlay(alignment: .top) {
            if isFrontmost && isDuplicating {
                DuplicatingToast().transition(.opacity)
            } else if isFrontmost && copied.value == true {
                CopiedToast().transition(.opacity)
            }
        }
        .todoRename($renameTarget, store: store, hosts: hosts)
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
        .confirmationDialog(
            ConversationRowActions.closeWhileWorkingTitle(tool: conversation?.tool ?? "claude"),
            isPresented: Binding(
                get: { isFrontmost && showingCloseConfirmation },
                set: { if !$0 { showingCloseConfirmation = false } }
            ),
            titleVisibility: .visible
        ) {
            Button("Close Conversation", role: .destructive) { closeConversationNow() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ConversationRowActions.closeWhileWorkingMessage)
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
        .sheet(isPresented: Binding(
            get: { isFrontmost && summaryContext != nil },
            set: { if !$0 { summaryContext = nil } }
        )) {
            DuplicateSummarySheet(
                text: $summaryText,
                onStart: confirmSummary,
                onCancel: { summaryContext = nil }
            )
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

    /// Servers…: the checklist sheet, and the restart question while the tool is working.
    private func serversPresentation(_ content: some View) -> some View {
        content
        .confirmationDialog(
            "Restart \(RowText.toolName(restartTarget?.tool ?? "claude"))?",
            isPresented: Binding(
                get: { isFrontmost && restartTarget != nil },
                set: { if !$0 { restartTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: restartTarget
        ) { conversation in
            Button("Restart", role: .destructive) { restart(conversation) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Restarting stops it where it is. It resumes with the new servers.")
        }
        .sheet(isPresented: Binding(
            get: { isFrontmost && serversTarget != nil },
            set: { if !$0 { serversTarget = nil } }
        )) {
            if let conversation = serversTarget {
                MCPServersSheet(
                    computer: conversation.computer, store: store, hosts: hosts,
                    selection: conversation.mcpServers,
                    allowsUnmanaged: conversation.mcpServers == nil || defaultServers(for: conversation.computer) == nil,
                    confirmTitle: "Save",
                    onConfirm: { names in
                        serversTarget = nil
                        saveServers(names, for: conversation)
                    },
                    onCancel: { serversTarget = nil }
                )
            }
        }
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
            if ConversationStart.needsConfirm(
                hasConversation: ConversationStart.hasStartedSession(conversation?.sessionId)
            ) {
                onTerminalBackground(toolStep)
            } else {
                onTerminalBackground(idleState)
            }
        case .preparing:
            onTerminalBackground(FrameStateBlock(showsProgress: true, title: preparingTitle))
        case let .ready(open):
            #if os(iOS)
            PhoneConversationView(
                conversation: conversation ?? open.conversation, config: open.config, store: store,
                terminal: terminal, isFrontmost: isFrontmost, needsApproval: liveStatus == .waiting,
                showsChat: $showsChat
            ) {
                liveTerminal(open)
            }
            .id(open.surfaceID)
            #else
            liveTerminal(open)
                .id(open.surfaceID)
                .task(id: clipboardSourceID) {
                    terminal.setClipboardCode([])
                    guard clipboardSourceID != nil else { return }
                    do {
                        let messages = try await store.conversationMessages(of: conversation ?? open.conversation, config: open.config)
                        guard !Task.isCancelled else { return }
                        terminal.setClipboardCode(CommandClipboard.candidates(in: messages.map(\.text)))
                    } catch {
                        // Selection remains usable when the transcript helper is unavailable.
                    }
                }
            #endif
        case let .problem(problem):
            onTerminalBackground(FrameStateView(
                problem: problem,
                actions: actions,
                tool: conversation?.tool,
                resumeCommand: conversation.map(ResumeCommand.string(for:))
            ))
        }
    }

    private func liveTerminal(_ open: OpenTodoConversation) -> some View {
        let conversation = open.conversation
        return TerminalSurface(
                config: open.config,
                mode: .attach(attachCommand(for: open)),
                hostName: conversation.computer.name,
                focusOnConnect: shouldFocusTerminal,
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
    }

    private var shouldFocusTerminal: Bool {
        #if os(iOS)
        !showsChat
        #else
        true
        #endif
    }

    private var toolStep: some View {
        let folder = store.project(id: todo.projectId)?.folder
        let computer = store.sectionComputers[todo.section]?.computer.name
        return VStack(spacing: DS.spacing.m) {
            Text("Start a conversation")
                .font(.title3.weight(.semibold))
            if let computer {
                Text(computer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No computer runs \(todo.section.rawValue) conversations yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let folder, !folder.isEmpty {
                Text(folder)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Picker("Tool", selection: $toolChoice) {
                Text("Claude").tag("claude")
                Text("Codex").tag("codex")
                Text("Cursor").tag("cursor")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .labelsHidden()
            if let computer = newConversationComputer, toolChoice != "cursor" {
                MCPServersStartRow(
                    computer: computer, store: store, hosts: hosts,
                    selection: serverSelection,
                    allowsUnmanaged: defaultServers(for: computer) == nil
                )
            }
            if let toolError {
                Text(toolError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: DS.spacing.m) {
                Button("Cancel", action: onDeleted)
                    .buttonStyle(.bordered)
                    .disabled(isStarting)
                if computer == nil {
                    // Start has nowhere to run until the section has a computer.
                    Button("Choose Computer") { openSettings(.sections(todo.section)) }
                        .buttonStyle(.borderedProminent)
                        .tint(DS.accent)
                } else {
                    Button(isStarting ? "Starting…" : "Start") { confirmTool() }
                        .buttonStyle(.borderedProminent)
                        .tint(DS.accent)
                        .disabled(isStarting)
                }
            }
        }
        .frame(maxWidth: 440)
        .padding(DS.spacing.xl)
        .onAppear {
            if toolChoice.isEmpty {
                toolChoice = ConversationStart.selectedTool(remembered: lastStartedTool.isEmpty ? nil : lastStartedTool)
            }
        }
    }

    private func confirmTool() {
        guard !isStarting else { return }
        let tool = ConversationStart.selectedTool(remembered: toolChoice)
        let servers = tool == "cursor" ? nil : serverSelection.wrappedValue
        lastStartedTool = tool
        isStarting = true
        toolError = nil
        Task {
            defer { isStarting = false }
            do {
                let conversation = try await startConversation(tool: tool, mcpServers: servers)
                loader.attachOpened(conversation)
            } catch {
                toolError = TodoHubStore.message(for: error)
            }
        }
    }

    private func startConversation(tool: String, mcpServers: [String]?) async throws -> Conversation {
        #if DEBUG
        if DemoFixtures.isEnabled {
            return try await DemoFixtures.loaderDependencies().openConversation(todo)
        }
        #endif
        guard let computer = store.sectionComputers[todo.section]?.computer else {
            throw TodoHubError.conflict("Section \(todo.section.rawValue) has no computer assigned")
        }
        guard let host = HostLookup.host(for: computer, in: hosts) else {
            throw HostLookup.Failure.noHost(computer)
        }
        let connection: (service: SessionService, config: HostConnectionConfig)
        do {
            connection = try SessionServiceFactory().make(for: host)
        } catch {
            throw HostLookup.Failure.keyUnavailable(host.displayName)
        }
        return try await store.openConversation(
            for: todo, tool: tool, config: connection.config, mcpServers: mcpServers
        )
    }

    /// The servers a new conversation starts with, exactly as the start state's checklist shows
    /// them: the defaults until the checklist changes them.
    private var serverSelection: Binding<[String]?> {
        Binding(
            get: {
                if hasServerChoice { return serverChoice }
                return newConversationComputer.flatMap(defaultServers(for:))
            },
            set: {
                serverChoice = $0
                hasServerChoice = true
            }
        )
    }

    /// The section's computer, where a new conversation starts, with its stored default.
    private var newConversationComputer: Computer? {
        guard let computer = store.sectionComputers[todo.section]?.computer else { return nil }
        return store.computers.first { $0.id == computer.id } ?? computer
    }

    /// What a new conversation on `computer` starts with: the project's default, else the computer's.
    private func defaultServers(for computer: Computer) -> [String]? {
        let stored = store.computers.first { $0.id == computer.id } ?? computer
        return MCPSelection.initial(project: store.project(id: todo.projectId), computer: stored)
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

    /// Phone and pop-out only. The shared column installs its own items.
    @ToolbarContentBuilder
    private var frameToolbar: some ToolbarContent {
        let ids = ConversationToolbar.frameItemIDs(showsTitle: !ownsWindow)
        #if os(iOS)
        if ids.contains(ConversationToolbar.titleID) {
            ToolbarItem(id: ConversationToolbar.titleID, placement: .principal) {
                ConversationToolbarTitle(title: todo.title, subtitle: meta(includeFolder: false), style: .centered,
                                         onRename: store.isOffline ? nil : { renameTarget = todo })
            }
        }
        ToolbarItem(id: ConversationToolbar.actionsID, placement: .topBarTrailing) {
            toolbarActions(showsCopy: false, showsPopOut: false, copyInMenu: true)
        }
        #else
        if ids.contains(ConversationToolbar.titleID) {
            ToolbarItem(id: ConversationToolbar.titleID, placement: .primaryAction) {
                ConversationToolbarTitle(title: todo.title, subtitle: meta(includeFolder: true), style: .leading,
                                         onRename: store.isOffline ? nil : { renameTarget = todo })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        ToolbarItem(id: ConversationToolbar.actionsID, placement: .primaryAction) {
            toolbarActions(showsCopy: true, showsPopOut: onPopOut != nil, copyInMenu: false)
        }
        #endif
    }

    private func toolbarActions(showsCopy: Bool, showsPopOut: Bool, copyInMenu: Bool) -> some View {
        ConversationToolbarActions(
            status: displayStatus,
            showsCopy: showsCopy,
            canCopy: conversation != nil,
            showsPopOut: showsPopOut,
            hasConversation: conversation != nil,
            canChange: conversation != nil && !store.isOffline,
            canRename: !store.isOffline,
            canChangeServers: canChangeServers,
            isReady: readyConversation != nil,
            isConnected: isConnected,
            copyInMenu: copyInMenu,
            onRename: { renameTarget = todo },
            onServers: changeServers,
            onCopy: copyResumeCommand,
            onPopOut: { onPopOut?() },
            onMemories: { showingMemories = true },
            onClose: closeConversation,
            onDelete: { showingDeleteConfirmation = true },
            onReconnect: { terminal.reconnect() },
            onCopyScreen: { copyScreen() },
            onPaste: { terminal.paste() },
            showsDuplicate: conversation != nil,
            duplicateName: DuplicateIn.proposedName(
                existingLabels: store.conversations(forTodo: todo.id).compactMap(\.label)
            ),
            onDuplicate: { tool, name in beginDuplicate(tool: tool, name: name) },
            isDuplicating: isDuplicating
        )
    }

    private func performToolbar(_ command: ConversationToolbarCommand) {
        switch command {
        case .rename: if !store.isOffline { renameTarget = todo }
        case .servers: changeServers()
        case .copyResume: copyResumeCommand()
        case .memories: showingMemories = true
        case .close: closeConversation()
        case .delete: showingDeleteConfirmation = true
        case .reconnect: terminal.reconnect()
        case .copyScreen: copyScreen()
        case .paste: terminal.paste()
        case let .duplicate(tool, name): beginDuplicate(tool: tool, name: name)
        }
    }

    /// The hub's status for this todo's conversation, as last heard.
    private var liveStatus: ConversationStatus? {
        conversation?.status ?? todo.conversationStatus
    }

    /// Live status; nil (no pill) when the todo has never had a conversation.
    private var displayStatus: ConversationDisplayStatus? {
        ConversationToolbar.displayStatus(todo: todo, store: store, selectedKey: appModel?.selectedConversationID)
    }

    private func meta(includeFolder: Bool) -> String {
        Self.subtitle(todo: todo, store: store, includeFolder: includeFolder, selectedKey: appModel?.selectedConversationID)
    }

    /// `section · computer · folder`, from the conversation on screen or else the section's
    /// computer. The folder is middle-truncated. The tool is the band, not this line.
    /// The detail column uses the same line for the window subtitle while several frames stay mounted.
    static func subtitle(todo: Todo, store: TodoHubStore, includeFolder: Bool, selectedKey: String? = nil) -> String {
        let target: (computer: String, folder: String)? = {
            if let conversation = store.displayed(forTodo: todo.id, selectedKey: selectedKey) {
                return (conversation.computer.name, conversation.cwd)
            }
            if let mapping = store.sectionComputers[todo.section] {
                let folder = store.project(id: todo.projectId)?.folder ?? ""
                return (mapping.computer.name, folder)
            }
            return nil
        }()
        guard let target else { return "\(todo.section.rawValue) · no computer" }
        let folder = includeFolder && !target.folder.isEmpty ? middleTruncated(target.folder) : nil
        return RowText.frameSubtitle(section: todo.section, computer: target.computer, folder: folder)
    }

    /// The tool this frame is for: the running conversation, else where a new one would start.
    private var chromeTool: String? {
        let tool = conversation?.tool ?? startTarget?.tool
        guard let tool, !tool.isEmpty else { return nil }
        return tool
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
        readyConversation?.surfaceID
    }

    /// After the surface's own focus-after-connect and whatever the list did with the click or
    /// key that selected this conversation.
    private func focusTerminalWhenWaiting() {
        guard shouldFocusTerminal else { return }
        #if DEBUG
        // Screenshots: `-uiDemoKeyboard down` keeps the soft keyboard away.
        if DemoFixtures.isEnabled, DemoFixtures.value(after: "-uiDemoKeyboard") == "down" { return }
        #endif
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            // Not from under the ⌘K palette's search field; closing it brings focus back.
            guard shouldFocusTerminal, appModel?.allowsTerminalAutoFocus ?? true else { return }
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

    private var clipboardSourceID: String? {
        guard isFrontmost, isConnected, let conversation else { return nil }
        return "\(conversation.id):\(conversation.sessionId):\(conversation.statusRevision):\(conversation.statusUpdatedAt ?? "")"
    }

    private var conversation: Conversation? {
        store.displayed(forTodo: todo.id, selectedKey: appModel?.selectedConversationID) ?? readyConversation?.conversation
    }

    /// Warm frames stay mounted. Only the one on screen refreshes limits. A popped-out
    /// placeholder has no bar.
    @ViewBuilder
    private var limitsBar: some View {
        if let target = limitsTarget, !isPoppedOut {
            UsageLimitsBar(
                computer: target.computer,
                tool: target.tool,
                sessionId: target.sessionId,
                polls: isFrontmost
            )
        }
    }

    /// The computer the chat runs on, and the tool whose limits to read there.
    /// A window that login does not have is left out by the script.
    private var limitsTarget: (computer: Computer, tool: String, sessionId: String?)? {
        if let conversation {
            let session = conversation.sessionId.isEmpty ? nil : conversation.sessionId
            return (conversation.computer, conversation.tool, session)
        }
        return nil
    }

    /// Where the conversation runs (or would start): the linked one, else the section's computer.
    private var startTarget: (computer: String, folder: String, tool: String)? {
        if let conversation {
            return (conversation.computer.name, conversation.cwd, conversation.tool)
        }
        if let mapping = store.sectionComputers[todo.section] {
            let folder = store.project(id: todo.projectId)?.folder ?? ""
            return (mapping.computer.name, folder, "")
        }
        return nil
    }

    // MARK: Actions

    private func reviewOpenedConversation() {
        #if os(iOS)
        guard !showsChat else { return } // Chat acknowledges after its text has loaded.
        #endif
        guard let conversation else { return }
        Task { await store.review(conversation) }
    }

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
            editAccess: { name in
                // The problem names the computer; the conversation on screen is the one it is about.
                if let computer = conversation?.computer, computer.name == name,
                   let host = HostLookup.host(for: computer, in: hosts) {
                    sheet = .editHost(host)
                } else {
                    openSettings(.access)
                }
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
        if !ConversationStart.hasStartedSession(conversation?.sessionId) {
            loader.reset()
            return
        }
        Task { await loader.start() }
    }

    private func copyResumeCommand() {
        guard let conversation else { return }
        copy(ResumeCommand.string(for: conversation))
    }

    private func copy(_ text: String) {
        PlatformSupport.pasteboardString = text
        showCopied()
    }

    /// The selection, or else the screen; the same toast as the resume command.
    private func copyScreen() {
        if terminal.copyScreen() { showCopied() }
    }

    private func showCopied() {
        copied.show(true)
    }

    /// Close from the menu or the column toolbar: asks first while the tool is still working,
    /// since closing stops it mid-task.
    private func closeConversation() {
        if conversation?.status == .busy {
            showingCloseConfirmation = true
        } else {
            closeConversationNow()
        }
    }

    /// Ends tmux and keeps the conversation resumable (the old "Kill Session").
    private func closeConversationNow() {
        perform("Couldn't Close Conversation") { conversation, config in
            try await store.closeConversation(conversation, config: config)
            loader.reset()
        }
    }

    /// Servers…: a linked Claude or Codex conversation, with the hub online.
    private var canChangeServers: Bool {
        guard let conversation else { return false }
        return !store.isOffline && conversation.tool != "cursor"
    }

    private func changeServers() {
        guard canChangeServers else { return }
        serversTarget = conversation
    }

    /// Stores the new selection; a tool that is running restarts to pick it up, after asking
    /// while it is working. One that isn't running uses it when it next starts.
    private func saveServers(_ names: [String]?, for conversation: Conversation) {
        guard names != conversation.mcpServers else { return }
        Task {
            do {
                try await store.setServers(names, for: conversation)
            } catch {
                failure = ActionFailure(
                    title: "Couldn't Change Servers",
                    message: ConversationRowActions.message(for: error, computer: conversation.computer)
                )
                return
            }
            guard readyConversation?.conversation.id == conversation.id else { return }
            let saved = store.conversations(forTodo: todo.id).first { $0.id == conversation.id } ?? conversation
            if saved.status == .busy {
                restartTarget = saved
            } else {
                restart(saved)
            }
        }
    }

    /// Ends the tmux session (the hub row stays open, unlike Close), then attaches again:
    /// `ai-todo-open` resumes the conversation with the servers it now has. A Codex
    /// conversation with no rollout yet can't be resumed, so it keeps running as it is.
    private func restart(_ conversation: Conversation) {
        perform("Couldn't Restart \(RowText.toolName(conversation.tool))") { _, config in
            let hasRollout = ServersRestart.checksRollout(conversation.tool)
                ? try? await store.codexHasRollout(conversation, config: config)
                : nil
            guard ServersRestart.decide(tool: conversation.tool, hasRollout: hasRollout) == .restart else {
                failure = ActionFailure(title: "Servers Saved", message: ServersRestart.notStartedMessage)
                return
            }
            try await store.endSession(conversation, config: config)
            loader.restart(conversation)
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
        case let .editHost(host):
            // Its Forget Host Key clears the identity this device trusted.
            HostEditorView(host: host)
        }
    }

    // MARK: Duplicate

    /// The PTY command for this conversation: a native fork when this duplicate asked for one,
    /// otherwise the usual `ai-todo-open` resume with the conversation's servers.
    private func attachCommand(for open: OpenTodoConversation) -> String {
        if let launch = duplicateLaunch, launch.conversationID == open.conversation.id,
           let command = launch.attachCommand {
            return command
        }
        return open.attachCommand
    }

    private func beginDuplicate(tool: String, name: String) {
        guard !isDuplicating, let source = conversation else { return }
        withAnimation { isDuplicating = true }
        let openConfig = readyConversation?.config
        Task {
            // Off while the summary sheet is up; Start turns it back on.
            defer { withAnimation { isDuplicating = false } }
            do {
                let config = try openConfig ?? HostLookup.config(for: source.computer, in: hosts)
                let transcript = try await transcriptForDuplicate(source: source, tool: tool, config: config)
                switch DuplicateHandoff.decide(sourceTool: source.tool, destinationTool: tool, transcript: transcript) {
                case .askForSummary:
                    summaryText = try await store.summarizeConversation(source, config: config)
                    summaryContext = DuplicateSummaryContext(
                        source: source, tool: tool, name: name, transcript: transcript
                    )
                case .fork, .sendTranscript:
                    let plan = DuplicateHandoff.plan(
                        source: source, destinationTool: tool, label: name,
                        transcript: transcript, confirmedSummary: nil
                    )
                    try await startDuplicate(plan, source: source, tool: tool, config: config)
                }
            } catch {
                failure = ActionFailure(
                    title: "Couldn't Duplicate Conversation",
                    message: ConversationRowActions.message(for: error, computer: source.computer)
                )
            }
        }
    }

    private func confirmSummary() {
        guard let context = summaryContext, !isDuplicating else { return }
        let text = summaryText
        summaryContext = nil
        withAnimation { isDuplicating = true }
        Task {
            defer { withAnimation { isDuplicating = false } }
            do {
                let plan = DuplicateHandoff.plan(
                    source: context.source, destinationTool: context.tool, label: context.name,
                    transcript: context.transcript, confirmedSummary: text
                )
                let config = try readyConversation?.config ?? HostLookup.config(for: context.source.computer, in: hosts)
                try await startDuplicate(plan, source: context.source, tool: context.tool, config: config)
            } catch {
                failure = ActionFailure(
                    title: "Couldn't Duplicate Conversation",
                    message: ConversationRowActions.message(for: error, computer: context.source.computer)
                )
            }
        }
    }

    /// Same tool with a native fork does not need the transcript. Anything else does.
    private func transcriptForDuplicate(
        source: Conversation, tool: String, config: HostConnectionConfig
    ) async throws -> String {
        if source.tool == tool, ForkCommand.arguments(tool: tool, sessionId: source.sessionId) != nil {
            return ""
        }
        return try await store.captureTranscript(of: source, config: config)
    }

    /// Creates the row only when the plan is a fork or a start, records the session the tool
    /// is using, then attaches that conversation. The source terminal is a different one.
    private func startDuplicate(
        _ plan: DuplicateHandoff.Plan, source: Conversation, tool: String, config: HostConnectionConfig
    ) async throws {
        var created: Conversation?
        try await DuplicateIn.perform(plan) {
            created = try await store.duplicateConversation(source: source, tool: tool, label: label(of: plan))
        }
        guard let created else { return }
        let ready = try await store.prepareDuplicate(created, plan: plan, config: config)
        if case let .start(text, _) = plan {
            duplicateLaunch = DuplicateLaunch(conversationID: ready.id, attachCommand: nil, paste: text)
        } else {
            duplicateLaunch = nil
        }
        appModel?.selectedConversationID = ready.listKey
        loader.show(ready)
    }

    private func label(of plan: DuplicateHandoff.Plan) -> String {
        switch plan {
        case let .fork(_, label), let .start(_, label): return label
        case .cancelled: return ""
        }
    }

    /// The new tool is connected: type the transcript or the edited summary, then Enter. The
    /// tool has usually not turned bracketed paste on yet, so this waits for it; otherwise each
    /// newline in the text would submit a piece of it.
    private func deliverDuplicateText() {
        guard let launch = duplicateLaunch,
              launch.conversationID == readyConversation?.conversation.id,
              let paste = launch.paste else { return }
        // Kept until it is typed: a reconnect during the wait delivers it on the next connect.
        handoffTask?.cancel()
        handoffTask = Task {
            guard await terminal.submitWhenPasteReady(paste) else { return }
            duplicateLaunch?.paste = nil
        }
    }
}

private struct DuplicateLaunch {
    var conversationID: String
    var attachCommand: String?
    var paste: String?
}

private struct DuplicateSummaryContext {
    var source: Conversation
    var tool: String
    var name: String
    var transcript: String
}

/// Resolves tool colors in the terminal's light or dark scheme, which can differ from the app.
private struct TerminalColorScheme: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("terminal.theme") private var themeRaw = TerminalTheme.system.rawValue

    func body(content: Content) -> some View {
        let palette = TerminalAppearance.palette(
            theme: TerminalTheme(rawValue: themeRaw) ?? .system,
            colorScheme: colorScheme
        )
        content.environment(\.colorScheme, palette == .dark ? .dark : .light)
    }
}

/// Icon and name across the top of the terminal, in the terminal's own light or dark scheme.
private struct ToolBand: View {
    let tool: String

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("terminal.theme") private var themeRaw = TerminalTheme.system.rawValue

    var body: some View {
        let palette = TerminalAppearance.palette(
            theme: TerminalTheme(rawValue: themeRaw) ?? .system,
            colorScheme: colorScheme
        )
        HStack(spacing: DS.spacing.s) {
            ToolIcon(tool: tool, side: 26)
            Text(RowText.toolName(tool))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.color(for: AITool(rawValue: tool)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.spacing.m)
        .padding(.vertical, DS.spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Color(palette.background)
                AppTheme.color(for: AITool(rawValue: tool)).opacity(0.08)
            }
        }
        .modifier(TerminalColorScheme())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Whether Servers… restarts the tool after saving a new selection.
enum ServersRestart: Equatable {
    case restart
    /// Saved only: the new servers apply when the tool next starts.
    case saveOnly

    static let notStartedMessage =
        "Codex can't restart a conversation before its first message. The new servers apply when it next starts."

    /// Only Codex needs the rollout check: Claude starts with `--session-id` when it has no transcript.
    static func checksRollout(_ tool: String) -> Bool { tool == "codex" }

    /// `hasRollout` is nil when the check didn't run or failed: restart as usual rather than block.
    static func decide(tool: String, hasRollout: Bool?) -> ServersRestart {
        checksRollout(tool) && hasRollout == false ? .saveOnly : .restart
    }
}

private struct ActionFailure {
    let title: String
    let message: String
}

private enum FrameSheet: Identifiable {
    case settings(SettingsDestination)
    case hostEditor(HostEditorPrefill)
    case editHost(HostEntity)

    var id: String {
        switch self {
        case let .settings(destination): "settings-\(destination)"
        case let .hostEditor(prefill): "host-\(prefill.id)"
        case let .editHost(host): "edit-host-\(host.id)"
        }
    }
}

