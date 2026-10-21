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
    /// The tool step. Empty until the frame appears, then the device's last tool, or Claude.
    @AppStorage(ConversationStart.storageKey) private var lastStartedTool = ""
    @State private var toolChoice = ""
    @State private var isStarting = false
    @State private var toolError: String?

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
            isConnected: isConnected
        )
    }

    private var frame: some View {
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
            if ConversationStart.needsConfirm(
                hasConversation: ConversationStart.hasStartedSession(store.conversations[todo.id]?.sessionId)
            ) {
                onTerminalBackground(toolStep)
            } else {
                onTerminalBackground(idleState)
            }
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
                Text("No computer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                Button(isStarting ? "Starting…" : "Start") { confirmTool() }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.accent)
                    .disabled(isStarting || store.sectionComputers[todo.section] == nil)
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
        lastStartedTool = tool
        isStarting = true
        toolError = nil
        Task {
            defer { isStarting = false }
            do {
                let conversation = try await startConversation(tool: tool)
                loader.attachOpened(conversation)
            } catch {
                toolError = TodoHubStore.message(for: error)
            }
        }
    }

    private func startConversation(tool: String) async throws -> Conversation {
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
        return try await store.openConversation(for: todo, tool: tool, config: connection.config)
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
                ConversationToolbarTitle(title: todo.title, subtitle: meta(includeFolder: false), style: .centered)
            }
        }
        ToolbarItem(id: ConversationToolbar.actionsID, placement: .topBarTrailing) {
            toolbarActions(showsCopy: false, showsPopOut: false, copyInMenu: true)
        }
        #else
        if ids.contains(ConversationToolbar.titleID) {
            ToolbarItem(id: ConversationToolbar.titleID, placement: .primaryAction) {
                ConversationToolbarTitle(title: todo.title, subtitle: meta(includeFolder: true), style: .leading)
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
            isReady: readyConversation != nil,
            isConnected: isConnected,
            copyInMenu: copyInMenu,
            onCopy: copyResumeCommand,
            onPopOut: { onPopOut?() },
            onMemories: { showingMemories = true },
            onClose: closeConversation,
            onDelete: { showingDeleteConfirmation = true },
            onReconnect: { terminal.reconnect() },
            onCopyScreen: { terminal.copyScreen() },
            onPaste: { terminal.paste() }
        )
    }

    private func performToolbar(_ command: ConversationToolbarCommand) {
        switch command {
        case .copyResume: copyResumeCommand()
        case .memories: showingMemories = true
        case .close: closeConversation()
        case .delete: showingDeleteConfirmation = true
        case .reconnect: terminal.reconnect()
        case .copyScreen: terminal.copyScreen()
        case .paste: terminal.paste()
        }
    }

    /// The hub's status for this todo's conversation, as last heard.
    private var liveStatus: ConversationStatus? {
        store.conversations[todo.id]?.status ?? todo.conversationStatus
    }

    /// Live status; nil (no pill) when the todo has never had a conversation.
    private var displayStatus: ConversationDisplayStatus? {
        ConversationToolbar.displayStatus(todo: todo, store: store)
    }

    private func meta(includeFolder: Bool) -> String {
        Self.subtitle(todo: todo, store: store, includeFolder: includeFolder)
    }

    /// `section · computer · folder`, from the conversation or else the section's
    /// computer. The folder is middle-truncated. The tool is the band, not this line.
    /// The detail column uses the same line for the window subtitle while several frames stay mounted.
    static func subtitle(todo: Todo, store: TodoHubStore, includeFolder: Bool) -> String {
        let target: (computer: String, folder: String)? = {
            if let conversation = store.conversations[todo.id] {
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
        if !ConversationStart.hasStartedSession(store.conversations[todo.id]?.sessionId) {
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

