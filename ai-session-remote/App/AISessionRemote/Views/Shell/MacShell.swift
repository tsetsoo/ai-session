import AISessionCore
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The Mac app, and iPad in regular width: sidebar, list column and the selected todo's
/// conversation frame, like the Claude desktop app.
struct MacShell: View {
    /// Settings as a sheet, optionally opened on one destination (iPad, and fixes like the
    /// token banner's Open Settings; the Mac's ⌘, opens the Settings window).
    private struct SettingsRequest: Identifiable {
        let id = UUID()
        let initial: SettingsDestination?
    }

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettingsWindow
    #endif
    @State private var query = ""
    @State private var settings: SettingsRequest?
    @State private var showingAdd = false
    @State private var showingNewFromConversation = false
    /// The palette's "Link a conversation to …".
    @State private var linkTarget: Todo?
    /// ⌘K.
    @State private var showingPalette = false
    /// `-uiDemoPalette <query>`: the palette opens with this query.
    @State private var initialPaletteQuery = ""
    /// ⏎, a double-click or Open for the selected todo's frame.
    @State private var frameRequest: FrameRequest?
    /// A computer's Other Sessions, On This Computer or Open Shell, shown in the detail column.
    @State private var computerPage: ComputerPage?

    private var store: TodoHubStore { model.store }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(selection: $model.sidebarSelection) { settings = SettingsRequest(initial: nil) }
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 320)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 300, ideal: 352, max: 520)
        } detail: {
            // Its own view, so choosing a conversation does not rebuild the list column.
            ShellDetail(frameRequest: $frameRequest, computerPage: computerPage, onOpen: open)
        }
        .tint(DS.accent)
        .environment(\.openAppSettings) { settings = SettingsRequest(initial: $0) }
        .environment(\.listPrimaryAction, start)
        .sheet(item: $settings) { request in
            SettingsView(initial: request.initial)
        }
        .sheet(isPresented: $showingAdd) {
            AddTodoSheet(fixedSection: selectedSection, store: store)
                .tint(DS.accent)
        }
        .sheet(isPresented: $showingNewFromConversation) {
            NewTodoFromConversationSheet(store: store)
                .tint(DS.accent)
        }
        .sheet(item: $linkTarget) { todo in
            LinkConversationSheet(todo: todo, store: store)
                .tint(DS.accent)
        }
        .overlay {
            if showingPalette {
                CommandPalette(isPresented: $showingPalette, selectedTodoID: visibleTodoID,
                               initialQuery: initialPaletteQuery, onActivate: activate,
                               onDismiss: returnFocusToTerminal)
            }
        }
        // While it is open, terminals leave keyboard focus in its search field.
        .onChange(of: showingPalette, initial: true) { _, open in model.isPaletteOpen = open }
        .onDisappear { model.isPaletteOpen = false }
        // ⌘K, ⌘1–⌘9 and ⌘N in the Conversation menu act on this window's shell.
        .focusedSceneValue(\.shellCommands, shellCommands)
        .todoStoreErrorAlert(store)
        .onChange(of: model.sidebarSelection) { _, _ in
            query = ""
            computerPage = nil
        }
        .onAppear(perform: applyInitialSelection)
        // A tapped "needs you" notification (routed by AppModel): select it only. The
        // selection attaches if it runs and never starts one; a popped-out one comes forward.
        .onChange(of: model.pendingOpenTodoID, initial: true) { _, todoID in
            guard let todoID, let todo = store.todos.first(where: { $0.id == todoID }) else { return }
            model.pendingOpenTodoID = nil
            switch sidebarItem {
            case .needsYou, .runningNow: break
            case .section(todo.section): break
            default: model.sidebarSelection = .needsYou
            }
            computerPage = nil
            model.selectedTodoID = todo.id
            #if os(macOS)
            if model.poppedOut.contains(todo.id) { model.popOut(todo.id, openWindow: openWindow) }
            #endif
        }
        // The Home-screen "New Todo" quick action (iPad in regular width): the New Todo sheet,
        // or nothing while the todo server isn't set up.
        .onChange(of: model.quickAddFocusRequested, initial: true) { _, requested in
            guard requested else { return }
            model.quickAddFocusRequested = false
            if model.isConfigured { showingAdd = true }
        }
        .task { await model.startSync() }
        // One listing for this shell. The first pass (still 0) lists every computer; a later
        // bump lists only computers whose conversations changed after their listing.
        .task(id: model.automaticLivenessID(hostIDs: hosts.map(\.id))) {
            let scope: AppModel.LivenessScope = model.relistRequests == 0 ? .full : .stale
            await model.refreshLiveness(hosts: hosts, scope: scope)
        }
    }

    // MARK: List column

    private var sidebarItem: AppModel.SidebarItem { model.sidebarSelection ?? .runningNow }

    @ViewBuilder
    private var contentColumn: some View {
        let item = sidebarItem
        Group {
            if model.isConfigured {
                list(for: item)
            } else {
                notConfigured
            }
        }
        .navigationTitle(ContentHeader.title(for: item, computers: store.computers))
        #if os(macOS)
        .navigationSubtitle(ContentHeader.subtitle(for: item, board: model.board) {
            store.sectionComputers[$0]?.computer.name
        })
        #endif
        .searchable(text: $query, prompt: "Search")
        .toolbar {
            // Projects has its own + (New Project) instead.
            if sidebarItem != .projects {
                ToolbarItem(id: "list.newTodo", placement: .primaryAction) {
                    // Click: new todo. The menu (its arrow on the Mac, a hold on iPad): new todo from
                    // an existing conversation.
                    Menu {
                        Button {
                            showingAdd = true
                        } label: {
                            Label("New Todo", systemImage: "plus")
                        }
                        Button {
                            showingNewFromConversation = true
                        } label: {
                            Label("New Todo from Conversation…", systemImage: "text.bubble")
                        }
                    } label: {
                        Label("New Todo", systemImage: "plus")
                    } primaryAction: {
                        showingAdd = true
                    }
                    .help("New Todo")
                    .disabled(!model.isConfigured || store.isOffline)
                }
            }
        }
    }

    @ViewBuilder
    private func list(for item: AppModel.SidebarItem) -> some View {
        switch item {
        case .needsYou:
            ConversationListView(filter: .constant(.needsYou), showsFilterPicker: false,
                                 query: query, selection: selection, onOpen: open)
        case .runningNow:
            ConversationListView(filter: .constant(.running), showsFilterPicker: false,
                                 showsShortcuts: Self.showsShortcuts, query: query, selection: selection,
                                 onOpen: open)
        case let .section(section):
            TodoListView(sections: [section], query: query, selection: selection, onOpen: open)
        case .projects:
            ProjectsList(store: store, selection: Binding(
                get: { model.selectedProjectID },
                set: { model.selectedProjectID = $0 }
            ))
        case let .computer(id):
            if let computer = store.computers.first(where: { $0.id == id }) {
                // Other Sessions, On This Computer and Open Shell select like conversations and
                // open in the detail column: the list column is too narrow for them.
                ComputerDetailView(computer: computer, query: query, selection: selection, onOpen: open)
                    .id(id)
            } else {
                ContentUnavailableView("Computer Not Found", systemImage: "desktopcomputer")
            }
        }
    }

    /// ⌘1–⌘9 hints in Running now: a keyboard is a given on the Mac only.
    private static var showsShortcuts: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private var notConfigured: some View {
        ContentUnavailableView {
            Label("Connect to your todo server", systemImage: "checklist")
        } description: {
            Text("Enter the server address and API token to see your todos.")
        } actions: {
            Button("Open Settings") { settings = SettingsRequest(initial: .server) }
                .buttonStyle(AccentButtonStyle())
        }
    }

    /// The section list, when one is selected. The toolbar sheet asks for a section otherwise.
    private var selectedSection: TodoSection? {
        if case let .section(section) = sidebarItem { return section }
        return nil
    }

    // MARK: Fast paths

    /// For the Conversation menu; none while one of the shell's sheets is up.
    private var shellCommands: ShellCommands? {
        guard settings == nil, !showingAdd, !showingNewFromConversation, linkTarget == nil else { return nil }
        let canAdd = model.isConfigured && !store.isOffline
        return ShellCommands(
            goTo: { showingPalette = true },
            conversationCount: min(model.board.runningNow.count, 9),
            openConversation: { n in
                guard let todo = PaletteModel.shortcutTarget(n, board: model.board, todos: store.todos) else { return }
                showingPalette = false
                go(to: todo)
            },
            newTodo: canAdd ? {
                showingPalette = false
                showingAdd = true
            } : nil
        )
    }

    /// The todo whose conversation the detail column shows.
    private var visibleTodoID: String? {
        guard sidebarItem != .projects, computerPage == nil else { return nil }
        return model.selectedTodoID
    }

    /// A palette row: ⏎ opens it here, ⌘⏎ a conversation or todo in its own window.
    private func activate(_ item: PaletteItem, newWindow: Bool) {
        switch item {
        case let .conversation(todo, _, _, _), let .todo(todo, _, _):
            #if os(macOS)
            if newWindow {
                model.popOut(todo.id, openWindow: openWindow)
                return
            }
            #endif
            go(to: todo)
        case let .project(project):
            model.sidebarSelection = .projects
            model.selectedProjectID = project.id
        case .action(.newTodo):
            showingAdd = true
        case let .action(.linkConversation(todoID, _)):
            linkTarget = store.todos.first { $0.id == todoID }
        case .action(.newTodoFromConversation):
            showingNewFromConversation = true
        case .action(.openSettings):
            #if os(macOS)
            openSettingsWindow()
            #else
            settings = SettingsRequest(initial: nil)
            #endif
        }
    }

    /// ⌘K and ⌘1–⌘9: show the todo in a list that has it, select it and start (or resume) its
    /// conversation, like ⏎. A popped-out one comes forward instead.
    private func go(to todo: Todo) {
        model.sidebarSelection = Self.sidebarTarget(showing: todo, from: sidebarItem, board: model.board)
        open(todo)
        // Already attached, nothing reconnects to take focus: type into it straight away.
        model.requestTerminalFocus(todoID: todo.id)
    }

    /// Esc or a click outside the palette: keyboard focus back in the terminal on screen.
    private func returnFocusToTerminal() {
        if let id = Self.terminalToFocus(visibleTodoID: visibleTodoID, poppedOut: model.poppedOut) {
            model.requestTerminalFocus(todoID: id)
        }
    }

    /// The terminal the detail column shows, if any: a popped-out todo shows a placeholder.
    static func terminalToFocus(visibleTodoID: String?, poppedOut: Set<String>) -> String? {
        guard let visibleTodoID, !poppedOut.contains(visibleTodoID) else { return nil }
        return visibleTodoID
    }

    /// The current list when it has the todo, else Running now for a running conversation, else
    /// the todo's section.
    static func sidebarTarget(showing todo: Todo, from current: AppModel.SidebarItem,
                              board: ConversationBoard) -> AppModel.SidebarItem {
        let status = board.status(forTodo: todo.id)
        let isRunning = status.map { $0 != .closed } ?? false
        switch current {
        case .needsYou where status == .needsYou: return current
        case .runningNow where isRunning: return current
        case .section(todo.section): return current
        default: return isRunning ? .runningNow : .section(todo.section)
        }
    }

    // MARK: Selection

    /// Todo ids, and a computer's pages by `ComputerPage.tag`.
    private var selection: Binding<String?> {
        Binding(get: { computerPage?.tag ?? model.selectedTodoID }, set: { tag in
            if let page = ComputerPage(tag: tag) {
                computerPage = page
                model.selectedTodoID = nil
            } else {
                computerPage = nil
                model.selectedTodoID = tag
            }
        })
    }

    /// "Open" from a row's context menu: select it and start (or resume) it.
    private func open(_ todo: Todo) {
        computerPage = nil
        model.selectedTodoID = todo.id
        start(todo.id)
    }

    /// ⏎ or a double-click on a row: start (or resume) its conversation. A page row just shows.
    private func start(_ tag: String) {
        guard ComputerPage(tag: tag) == nil else { return }
        #if os(macOS)
        if model.poppedOut.contains(tag) {
            model.popOut(tag, openWindow: openWindow)
            return
        }
        #endif
        frameRequest = FrameRequest(kind: .start, todoID: tag)
    }

    private func applyInitialSelection() {
        #if DEBUG
        if DemoFixtures.isEnabled {
            // `-uiDemoSidebar needsyou|running|Sp|I|Si|P|computer:<id>` and `-uiDemoOpen <todo id>`.
            // Only on first appearance: an iPad shell swap keeps what was selected.
            if model.sidebarSelection == nil {
                model.sidebarSelection = DemoFixtures.value(after: "-uiDemoSidebar")
                    .flatMap(AppModel.SidebarItem.init(demoArgument:)) ?? .runningNow
            }
            if model.selectedTodoID == nil {
                model.selectedTodoID = DemoFixtures.value(after: "-uiDemoOpen") ?? model.board.runningNow.first?.todoId
            }
            // `-uiDemoPalette <query>`: the ⌘K palette open with that query ("" for none).
            if let query = DemoFixtures.value(after: "-uiDemoPalette") {
                initialPaletteQuery = query
                showingPalette = true
            }
            #if os(macOS)
            // `-uiDemoPopOut <todo id>`: that conversation in its own window.
            if let id = DemoFixtures.value(after: "-uiDemoPopOut") {
                model.popOut(id, openWindow: openWindow)
                // `-uiDemoMainKey`: the main window back in front, to show its placeholder active.
                if ProcessInfo.processInfo.arguments.contains("-uiDemoMainKey") {
                    let title = store.todos.first { $0.id == id }?.title
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        NSApplication.shared.windows
                            .first { $0.isVisible && $0.canBecomeMain && $0.title != title }?
                            .makeKeyAndOrderFront(nil)
                    }
                }
            }
            // Launched from a script, the window would stay inactive and draw its selection grey.
            NSApplication.shared.activate(ignoringOtherApps: true)
            // `-uiDemoFocusList`: keyboard focus in the list column, to show the focused selection.
            if ProcessInfo.processInfo.arguments.contains("-uiDemoFocusList") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: Self.focusListColumn)
            }
            #endif
            return
        }
        // `-demoProjects` (canned projects, see TodoHubDemo): open on Projects.
        if let demo = store.demo, model.sidebarSelection == nil {
            model.sidebarSelection = .projects
            model.selectedProjectID = ProjectsDemo.projectPage(store) ?? demo.projects.first?.id
        }
        #endif
        if model.sidebarSelection == nil { model.sidebarSelection = .runningNow }
    }

    #if DEBUG && os(macOS)
    /// The key window's second table from the left: the list column (the first is the sidebar).
    private static func focusListColumn() {
        guard let window = NSApplication.shared.keyWindow, let root = window.contentView else { return }
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        let sorted = tables(in: root).sorted {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
        if sorted.count > 1 { window.makeFirstResponder(sorted[1]) }
    }
    #endif
}

// MARK: - Detail column

/// The detail column. Kept off `MacShell`'s body so clicking a conversation does not rebuild
/// the list. Conversations you have already opened stay mounted underneath Projects and a
/// computer page, so coming back shows the terminal that is still attached.
private struct ShellDetail: View {
    @Binding var frameRequest: FrameRequest?
    let computerPage: ComputerPage?
    let onOpen: (Todo) -> Void

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]

    private var store: TodoHubStore { model.store }

    private var showsConversation: Bool {
        model.sidebarSelection != .projects && computerPage == nil
    }

    var body: some View {
        ZStack {
            ConversationColumn(request: $frameRequest, showsConversation: showsConversation)
            if model.sidebarSelection == .projects {
                projectDetail
            } else if let page = computerPage, case let .computer(id) = model.sidebarSelection,
                      let computer = store.computers.first(where: { $0.id == id }),
                      let host = HostLookup.host(for: computer, in: hosts) {
                NavigationStack {
                    page.destination(computer: computer, host: host)
                }
                .id("\(id)|\(page.rawValue)")
            } else if showsConversation, model.selectedTodoID == nil {
                ContentUnavailableView {
                    Label("Select a conversation", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("⌘K to jump · ⌘N new todo")
                }
            }
        }
    }

    /// The selected project's page. Opening one of its todos selects that todo in its section
    /// and starts (or resumes) it, so the conversation shows in this column as usual.
    @ViewBuilder
    private var projectDetail: some View {
        if let id = model.selectedProjectID {
            NavigationStack {
                ProjectDetailView(projectId: id, store: store) { todo in
                    model.sidebarSelection = .section(todo.section)
                    onOpen(todo)
                }
            }
            .id(id)
        } else {
            ContentUnavailableView {
                Label("Select a project", systemImage: "folder")
            } description: {
                Text("Projects group todos, conversations and memories by folder.")
            }
        }
    }
}

/// The conversations whose terminals stay alive. Selecting one that is already mounted shows
/// it immediately. A new running conversation waits `SelectionAttacher.delay` before it is
/// mounted, so arrowing through the list does not attach every row.
private struct ConversationColumn: View {
    @Binding var request: FrameRequest?
    let showsConversation: Bool

    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var shown: [String] = []
    /// A running conversation selected, not mounted yet: the settle window.
    @State private var pendingID: String?
    /// Commands from this column's single toolbar to the frontmost frame.
    @State private var toolbarRequest: ConversationToolbarRequest?
    /// The frontmost frame's terminal, for enabling Reconnect / Copy / Paste.
    @State private var terminalState: ConversationTerminalState?

    private var frontmostID: String? {
        guard showsConversation else { return nil }
        return model.selectedTodoID
    }

    var body: some View {
        ZStack {
            ForEach(shown, id: \.self) { id in
                if let todo = model.store.todos.first(where: { $0.id == id }) {
                    ConversationDetail(
                        todo: todo, request: $request, toolbarRequest: $toolbarRequest,
                        isFrontmost: frontmostID == id, sharesColumn: true,
                        attachImmediately: true
                    ) {
                        shown.removeAll { $0 == id }
                        if model.selectedTodoID == id { model.selectedTodoID = nil }
                    }
                    .opacity(frontmostID == id ? 1 : 0)
                    .allowsHitTesting(frontmostID == id)
                    .accessibilityHidden(frontmostID != id)
                    .zIndex(frontmostID == id ? 1 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let pendingID, pendingID == model.selectedTodoID, showsConversation, !shown.contains(pendingID) {
                // The same blank the frame shows while a selection settles.
                Color.clear.modifier(OnTerminalBackground())
                    .allowsHitTesting(false)
            }
        }
        .background { windowTitle }
        .onPreferenceChange(ConversationTerminalStateKey.self) { terminalState = $0 }
        .toolbar { columnToolbar }
        .onChange(of: model.selectedTodoID, initial: true) { _, id in syncSelection(id) }
        .onChange(of: model.store.todos.map(\.id)) { _, ids in
            let alive = Set(ids)
            let kept = shown.filter { alive.contains($0) }
            if kept != shown { shown = kept }
            if let pendingID, !alive.contains(pendingID) { self.pendingID = nil }
        }
        .task(id: pendingID) {
            guard let pendingID else { return }
            try? await Task.sleep(for: .seconds(SelectionAttacher.delay))
            guard !Task.isCancelled, self.pendingID == pendingID else { return }
            shown = WarmConversationMount.select(pendingID, in: shown, protects: protectsTerminal)
            self.pendingID = nil
        }
    }

    /// The column owns the window title: each mounted frame would otherwise publish its own.
    @ViewBuilder
    private var windowTitle: some View {
        if showsConversation, let id = model.selectedTodoID,
           let todo = model.store.todos.first(where: { $0.id == id }) {
            Color.clear
                .frame(width: 0, height: 0)
                .navigationTitle(todo.title)
                #if os(macOS)
                .navigationSubtitle(ConversationFrame.subtitle(todo: todo, store: model.store, includeFolder: true))
                #endif
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// One toolbar for every mounted frame. Each item's identifier is its `ToolbarItem` id,
    /// and those ids do not change with the selection, so AppKit updates the items. A view
    /// `.id()` is not an `NSToolbar` identifier: the old Mac group used those, and a
    /// selection change inserted a second copy of an item already in the bar.
    @ToolbarContentBuilder
    private var columnToolbar: some ToolbarContent {
        if showsConversation, let id = model.selectedTodoID,
           let todo = model.store.todos.first(where: { $0.id == id }) {
            let ids = ConversationToolbar.columnItemIDs(todoID: id)
            let state = terminalState?.todoID == id ? terminalState : nil
            let hasConversation = model.store.conversations[todo.id] != nil
            #if os(iOS)
            ToolbarItem(id: ids[0], placement: .principal) {
                ConversationToolbarTitle(
                    title: todo.title,
                    subtitle: ConversationFrame.subtitle(
                        todo: todo, store: model.store, includeFolder: false
                    ),
                    style: .centered
                )
            }
            ToolbarItem(id: ids[1], placement: .topBarTrailing) {
                columnActions(
                    todo: todo, hasConversation: hasConversation, state: state,
                    showsCopy: false, showsPopOut: false, copyInMenu: true
                )
            }
            #else
            ToolbarItem(id: ids[0], placement: .primaryAction) {
                ConversationToolbarTitle(
                    title: todo.title,
                    subtitle: ConversationFrame.subtitle(
                        todo: todo, store: model.store, includeFolder: true
                    ),
                    style: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ToolbarItem(id: ids[1], placement: .primaryAction) {
                columnActions(
                    todo: todo, hasConversation: hasConversation, state: state,
                    showsCopy: true, showsPopOut: true, copyInMenu: false
                )
            }
            #endif
        }
    }

    private func columnActions(
        todo: Todo,
        hasConversation: Bool,
        state: ConversationTerminalState?,
        showsCopy: Bool,
        showsPopOut: Bool,
        copyInMenu: Bool
    ) -> some View {
        ConversationToolbarActions(
            status: ConversationToolbar.displayStatus(todo: todo, store: model.store),
            showsCopy: showsCopy,
            canCopy: hasConversation,
            showsPopOut: showsPopOut,
            hasConversation: hasConversation,
            canChange: hasConversation && !model.store.isOffline,
            isReady: state?.isReady ?? false,
            isConnected: state?.isConnected ?? false,
            copyInMenu: copyInMenu,
            onCopy: { send(.copyResume, for: todo.id) },
            onPopOut: popOut(todo.id),
            onMemories: { send(.memories, for: todo.id) },
            onClose: { send(.close, for: todo.id) },
            onDelete: { send(.delete, for: todo.id) },
            onReconnect: { send(.reconnect, for: todo.id) },
            onCopyScreen: { send(.copyScreen, for: todo.id) },
            onPaste: { send(.paste, for: todo.id) }
        )
    }

    private func send(_ command: ConversationToolbarCommand, for todoID: String) {
        toolbarRequest = ConversationToolbarRequest(command: command, todoID: todoID)
    }

    private func popOut(_ todoID: String) -> () -> Void {
        #if os(macOS)
        return { model.popOut(todoID, openWindow: openWindow) }
        #else
        return {}
        #endif
    }

    private func syncSelection(_ id: String?) {
        guard let id, model.store.todos.contains(where: { $0.id == id }) else {
            pendingID = nil
            return
        }
        switch model.attachReadiness(forTodo: id) {
        case .running, .awaitingLiveness:
            if shown.contains(id) {
                pendingID = nil
                shown = WarmConversationMount.select(id, in: shown, protects: protectsTerminal)
            } else {
                pendingID = id
            }
        case .closed, .unknown:
            // In front of the warm terminals, not in one of their slots. Arrowing through
            // closed rows must not disconnect a live session.
            pendingID = nil
            shown = WarmConversationMount.select(id, in: shown, protects: protectsTerminal)
        }
    }

    /// Running, and a conversation still waiting on its first listing. Closed and unknown
    /// are the one card swapped in front.
    private func protectsTerminal(_ id: String) -> Bool {
        switch model.attachReadiness(forTodo: id) {
        case .running, .awaitingLiveness: return true
        case .closed, .unknown: return false
        }
    }
}

// MARK: - Selecting vs attaching

/// Turns the Mac's selection into attaching its conversation's terminal, never starting one.
///
/// - A selection settles for 150 ms first, so arrowing through the list attaches only where it
///   stops. Like `TerminalResizeDebouncer` it takes an injectable scheduler for tests. The
///   detail column waits that long before mounting a new frame, then selects with `immediate`
///   so the wait is not paid twice.
/// - It attaches only once the conversation's tmux session was listed alive: attaching runs
///   `ai-todo-open`, which would quietly recreate a dead session. If the computer hasn't been
///   listed yet it asks for a liveness refresh and waits; if that gets no answer it stays on
///   Start / Resume.
/// - It re-evaluates when the selected conversation's running state changes: starting to run
///   elsewhere attaches (debounced), closing drops to Start / Resume.
/// - A frame kept mounted behind the one on screen does not open a terminal. One that is
///   already attached stays attached, so coming back shows it at once.
@MainActor
@Observable
final class SelectionAttacher {
    typealias Scheduler = (@escaping @MainActor @Sendable () -> Void) -> Void

    nonisolated static let delay: TimeInterval = 0.15

    /// The selected todo's readiness; the detail reads it from `AppModel`, tests fake it.
    @ObservationIgnored var readiness: (String) -> AttachReadiness = { _ in .unknown }
    /// Delivers `.attach` / `.detach` to the frame.
    @ObservationIgnored var perform: (FrameRequest) -> Void = { _ in }

    /// Between a selection (or a change in its running state) and acting on it.
    private(set) var isSettling = false
    /// True after the first `evaluate`, so the frame can avoid a Start card flash before then.
    private(set) var hasEvaluated = false
    /// Bumped when the selection's computer needs a liveness refresh; the detail runs it.
    private(set) var livenessRequests = 0
    /// False while another conversation is the one on screen.
    private(set) var isFrontmost = true

    @ObservationIgnored private let scheduler: Scheduler
    @ObservationIgnored private(set) var selection: String?
    /// The selection's last definite state (`.running` or `.closed`): only a change acts.
    @ObservationIgnored private var lastKnown: AttachReadiness?
    @ObservationIgnored private var askedForLiveness = false
    /// Popped out into its own window: that window's attacher asks for liveness, not this one.
    @ObservationIgnored var isSuspended = false
    @ObservationIgnored private var generation = 0

    init(scheduler: @escaping Scheduler = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + SelectionAttacher.delay, execute: work)
    }) {
        self.scheduler = scheduler
    }

    /// - Parameter immediate: the caller already waited out `delay` (the detail column does,
    ///   before it mounts the frame). Evaluate in this turn instead of waiting again.
    func select(_ todoID: String?, immediate: Bool = false) {
        guard todoID != selection else { return }
        selection = todoID
        lastKnown = nil
        askedForLiveness = false
        hasEvaluated = false
        if todoID == nil {
            generation += 1
            isSettling = false
            hasEvaluated = true
        } else if immediate {
            generation += 1
            isSettling = false
            evaluate()
        } else {
            schedule()
        }
    }

    /// The same selection, evaluated afresh (Bring Back from a pop-out window).
    func reselect() {
        lastKnown = nil
        askedForLiveness = false
        if selection != nil { schedule() }
    }

    /// The detail column shows one conversation at a time and keeps the others mounted.
    /// Leaving cancels an attach that has not fired yet and leaves a live terminal up.
    /// Coming back to a live terminal does not attach again.
    func setFrontmost(_ frontmost: Bool) {
        guard frontmost != isFrontmost else { return }
        isFrontmost = frontmost
        if !frontmost {
            generation += 1
            isSettling = false
            return
        }
        guard selection != nil, lastKnown != .running else { return }
        schedule()
    }

    /// The newest liveness refresh ended without an answer and none is running
    /// (`AppModel.livenessAbandoned`): a selection still waiting asks again, or it would stay
    /// on "Connecting to …" for good.
    func livenessAbandoned() {
        guard let todoID = selection, readiness(todoID) == .awaitingLiveness else { return }
        askedForLiveness = false
        if !isSettling { evaluate() }
    }

    /// The board or liveness changed for the selection.
    func inputsChanged() {
        guard let todoID = selection, !isSettling else { return }
        if !isFrontmost {
            // A terminal left open in the background still has to drop when its session ends.
            if readiness(todoID) == .closed, lastKnown == .running {
                perform(FrameRequest(kind: .detach, todoID: todoID))
                lastKnown = .closed
            }
            return
        }
        schedule()
    }

    private func schedule() {
        generation += 1
        let thisGeneration = generation
        isSettling = true
        scheduler { @MainActor [weak self] in
            guard let self, self.generation == thisGeneration else { return }
            self.isSettling = false
            self.evaluate()
        }
    }

    private func evaluate() {
        hasEvaluated = true
        guard let todoID = selection else { return }
        switch readiness(todoID) {
        case .running:
            // A hidden frame must not open a second client.
            guard isFrontmost else { return }
            if lastKnown != .running { perform(FrameRequest(kind: .attach, todoID: todoID)) }
            lastKnown = .running
        case .closed:
            if lastKnown == .running { perform(FrameRequest(kind: .detach, todoID: todoID)) }
            lastKnown = .closed
        case .awaitingLiveness:
            guard isFrontmost else { return }
            if !askedForLiveness, !isSuspended {
                askedForLiveness = true
                livenessRequests += 1
            }
        case .unknown:
            // Neither attach (it could recreate a dead session) nor drop a live terminal.
            break
        }
    }
}

/// Which conversation frames stay mounted in the detail column. The most recently selected
/// running conversations stay, oldest first, so coming back to one shows the terminal that
/// is already attached. A closed conversation is one extra card in front of those; it does
/// not take a slot, and the next closed conversation replaces it.
enum WarmConversationMount {
    /// Three live terminals: the one on screen and the two you just left. Older ones disconnect.
    static let capacity = 3

    /// Mounts `id`. `protects` is true for a conversation whose terminal must stay (running,
    /// or still waiting on a listing). A closed or unknown id is shown in addition and
    /// replaces the previous one. The default treats every id as a live terminal.
    static func select(_ id: String, in ids: [String], protects: (String) -> Bool = { _ in true }) -> [String] {
        var warm = ids.filter(protects)
        guard protects(id) else { return warm + [id] }
        if let index = warm.firstIndex(of: id) {
            warm.remove(at: index)
        }
        warm.append(id)
        if warm.count > capacity {
            warm.removeFirst(warm.count - capacity)
        }
        return warm
    }
}

/// A todo's frame attached by its own `SelectionAttacher`: the shell's detail column (the
/// selection changes underneath it), each pop-out window (one todo), and the phone shell's
/// frame re-opened after an iPad shell swap.
struct ConversationDetail: View {
    let todo: Todo
    @Binding var request: FrameRequest?
    /// The column toolbar. Pop-out windows pass `.constant(nil)` and keep the frame's toolbar.
    var toolbarRequest: Binding<ConversationToolbarRequest?> = .constant(nil)
    /// The pop-out window itself, rather than the main window's detail.
    var isWindow = false
    /// False while this frame is kept mounted behind the conversation on screen.
    var isFrontmost = true
    /// Several frames share the detail column. See `ConversationFrame.sharesColumn`.
    var sharesColumn = false
    /// The column already waited `SelectionAttacher.delay` before mounting this frame.
    var attachImmediately = false
    let onDeleted: () -> Void

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var attacher = SelectionAttacher()
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif

    var body: some View {
        let readiness = model.attachReadiness(forTodo: todo.id)
        let poppedOut = !isWindow && model.poppedOut.contains(todo.id)
        TodoConversationScreen(
            todo: todo, store: model.store, onAppear: .onRequest, request: $request,
            placeholder: placeholder(readiness: readiness, poppedOut: poppedOut),
            isSuspended: poppedOut, isFrontmost: isFrontmost, sharesColumn: sharesColumn,
            toolbarRequest: toolbarRequest, onPopOut: popOutAction, onDeleted: onDeleted
        )
        .id(todo.id)
        .onChange(of: todo.id, initial: true) { _, id in
            // A request left for another todo must not fire when that one is selected again.
            // Clear it before select: an immediate attach writes a new request.
            if isFrontmost, request?.todoID != id { request = nil }
            attacher.readiness = { [model] in model.attachReadiness(forTodo: $0) }
            let request = $request
            attacher.perform = { request.wrappedValue = $0 }
            // Before select: an immediate attach must see whether this frame is on screen.
            attacher.setFrontmost(isFrontmost)
            attacher.select(id, immediate: attachImmediately)
        }
        .onChange(of: isFrontmost) { _, front in attacher.setFrontmost(front) }
        .onChange(of: readiness) { _, _ in attacher.inputsChanged() }
        .onChange(of: poppedOut, initial: true) { wasPoppedOut, poppedOut in
            attacher.isSuspended = poppedOut
            if wasPoppedOut, !poppedOut { attacher.reselect() }
        }
        .task(id: attacher.livenessRequests) {
            guard attacher.livenessRequests > 0 else { return }
            await model.refreshLiveness(hosts: hosts)
        }
        .onChange(of: model.livenessAbandoned) { _, _ in attacher.livenessAbandoned() }
    }

    private func placeholder(readiness: AttachReadiness, poppedOut: Bool) -> FramePlaceholder? {
        #if os(macOS)
        if poppedOut {
            return .poppedOut(showWindow: { model.popOut(todo.id, openWindow: openWindow) }, bringBack: bringBack)
        }
        #endif
        // The first body runs before select. A running conversation would otherwise flash Start.
        if !attacher.hasEvaluated {
            switch readiness {
            case .running, .awaitingLiveness: return .settling
            case .closed, .unknown: break
            }
        }
        switch readiness {
        case .running:
            return attacher.isSettling ? .settling : nil
        case .awaitingLiveness:
            let computer = model.store.conversations[todo.id]?.computer.name ?? "the computer"
            return attacher.isSettling ? .settling : .checking(computer: computer)
        case .closed, .unknown:
            return nil
        }
    }

    #if os(macOS)
    private var popOutAction: (() -> Void)? {
        isWindow ? nil : { model.popOut(todo.id, openWindow: openWindow) }
    }

    /// Closes the pop-out window; this frame then attaches again under the same rules.
    private func bringBack() {
        dismissWindow(id: ConversationWindow.id, value: todo.id)
        model.poppedOut.remove(todo.id)
    }
    #else
    private var popOutAction: (() -> Void)? { nil }
    #endif
}

#if os(macOS)
/// ⧉ / ⇧⌘O: one todo's conversation in its own window, keyed by todo id. The main window's
/// detail shows a placeholder meanwhile, so two clients don't fight over the terminal size.
struct ConversationWindow: View {
    static let id = "conversation"

    let todoID: String?

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var request: FrameRequest?

    /// Before the first refresh the todo may just not be loaded yet.
    private var isFirstSync: Bool {
        model.isConfigured && !model.store.hasLoadedOnce
    }

    var body: some View {
        Group {
            if let todoID, let todo = model.store.todos.first(where: { $0.id == todoID }) {
                ConversationDetail(todo: todo, request: $request, isWindow: true) { dismissWindow() }
            } else if todoID != nil, isFirstSync {
                FrameLoadingView(title: "Loading conversation…")
            } else {
                ContentUnavailableView("Conversation Not Found", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .environment(\.frameOwnsWindow, true)
        .tint(DS.accent)
        // Also when the window comes back through state restoration.
        .onAppear { if let todoID { model.poppedOut.insert(todoID) } }
        .onDisappear { if let todoID { model.poppedOut.remove(todoID) } }
        // Restored without the main window, nothing else would sync the todos.
        .task { await model.startSync() }
    }
}

extension AppModel {
    /// Opens the todo's own window, or brings it forward.
    func popOut(_ todoID: String, openWindow: OpenWindowAction) {
        poppedOut.insert(todoID)
        openWindow(id: ConversationWindow.id, value: todoID)
    }
}
#endif

#if DEBUG
extension AppModel.SidebarItem {
    /// `-uiDemoSidebar` values: needsyou, running, a section code, projects, or computer:<id>.
    init?(demoArgument: String) {
        switch demoArgument {
        case "needsyou": self = .needsYou
        case "running": self = .runningNow
        case "projects": self = .projects
        default:
            if let section = TodoSection(rawValue: demoArgument) {
                self = .section(section)
            } else if demoArgument.hasPrefix("computer:") {
                self = .computer(String(demoArgument.dropFirst("computer:".count)))
            } else {
                return nil
            }
        }
    }
}
#endif
