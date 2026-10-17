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
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @AppStorage(QuickAdd.sectionKey) private var quickAddSection = TodoSection.i.rawValue
    @State private var query = ""
    @State private var settings: SettingsRequest?
    @State private var showingAdd = false
    @State private var showingNewFromConversation = false
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
            detailColumn
        }
        .tint(DS.accent)
        .environment(\.openAppSettings) { settings = SettingsRequest(initial: $0) }
        .environment(\.listPrimaryAction, start)
        .sheet(item: $settings) { request in
            SettingsView(initial: request.initial)
        }
        .sheet(isPresented: $showingAdd) {
            AddTodoSheet(section: addSection, projects: store.projects) { section, title, projectId in
                Task { await store.createTodo(section: section, title: title, projectId: projectId) }
            }
            .tint(DS.accent)
        }
        .sheet(isPresented: $showingNewFromConversation) {
            NewTodoFromConversationSheet(store: store)
                .tint(DS.accent)
        }
        .todoStoreErrorAlert(store)
        .onChange(of: model.sidebarSelection) { _, _ in
            query = ""
            computerPage = nil
        }
        .onAppear(perform: applyInitialSelection)
        // A tapped "needs you" notification (routed by AppModel): select and open it.
        .onChange(of: model.pendingOpenTodoID, initial: true) { _, todoID in
            guard let todoID, let todo = store.todos.first(where: { $0.id == todoID }) else { return }
            model.pendingOpenTodoID = nil
            switch sidebarItem {
            case .needsYou, .runningNow: break
            case .section(todo.section): break
            default: model.sidebarSelection = .needsYou
            }
            open(todo)
        }
        // The Home-screen "New Todo" quick action (iPad in regular width): the New Todo sheet.
        .onChange(of: model.quickAddFocusRequested, initial: true) { _, requested in
            guard requested else { return }
            model.quickAddFocusRequested = false
            showingAdd = true
        }
        .task { await model.startSync() }
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
                ToolbarItem(placement: .primaryAction) {
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

    /// New todos go to the selected section, else the quick-add section.
    private var addSection: TodoSection {
        if case let .section(section) = sidebarItem { return section }
        return QuickAdd.section(from: quickAddSection)
    }

    // MARK: Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if sidebarItem == .projects {
            projectDetail
        } else if let page = computerPage, case let .computer(id) = sidebarItem,
           let computer = store.computers.first(where: { $0.id == id }),
           let host = HostLookup.host(for: computer, in: hosts) {
            NavigationStack {
                page.destination(computer: computer, host: host)
            }
            .id("\(id)|\(page.rawValue)")
        } else if let id = model.selectedTodoID, let todo = store.todos.first(where: { $0.id == id }) {
            // Selection attaches to a running conversation after 150 ms and never starts one;
            // ⏎, a double-click or Open does.
            ConversationDetail(todo: todo, request: $frameRequest) {
                model.selectedTodoID = nil
            }
        } else {
            ContentUnavailableView {
                Label("Select a conversation", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("⌘K to jump · ⌘N new todo")
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
                    open(todo)
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

// MARK: - Selecting vs attaching

/// Turns the Mac's selection into attaching its conversation's terminal, never starting one.
///
/// - A selection settles for 150 ms first, so arrowing through the list attaches only where it
///   stops. Like `TerminalResizeDebouncer` it takes an injectable scheduler for tests.
/// - It attaches only once the conversation's tmux session was listed alive: attaching runs
///   `ai-todo-open`, which would quietly recreate a dead session. If the computer hasn't been
///   listed yet it asks for a liveness refresh and waits; if that gets no answer it stays on
///   Start / Resume.
/// - It re-evaluates when the selected conversation's running state changes: starting to run
///   elsewhere attaches (debounced), closing drops to Start / Resume.
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
    /// Bumped when the selection's computer needs a liveness refresh; the detail runs it.
    private(set) var livenessRequests = 0

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

    func select(_ todoID: String?) {
        guard todoID != selection else { return }
        selection = todoID
        lastKnown = nil
        askedForLiveness = false
        if todoID == nil {
            generation += 1
            isSettling = false
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
        guard selection != nil, !isSettling else { return }
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
        guard let todoID = selection else { return }
        switch readiness(todoID) {
        case .running:
            if lastKnown != .running { perform(FrameRequest(kind: .attach, todoID: todoID)) }
            lastKnown = .running
        case .closed:
            if lastKnown == .running { perform(FrameRequest(kind: .detach, todoID: todoID)) }
            lastKnown = .closed
        case .awaitingLiveness:
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

/// A todo's frame attached by its own `SelectionAttacher`: the shell's detail column (the
/// selection changes underneath it), each pop-out window (one todo), and the phone shell's
/// frame re-opened after an iPad shell swap.
struct ConversationDetail: View {
    let todo: Todo
    @Binding var request: FrameRequest?
    /// The pop-out window itself, rather than the main window's detail.
    var isWindow = false
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
            isSuspended: poppedOut, onPopOut: popOutAction, onDeleted: onDeleted
        )
        .id(todo.id)
        .onChange(of: todo.id, initial: true) { _, id in
            // A request left for another todo must not fire when that one is selected again.
            if request?.todoID != id { request = nil }
            attacher.readiness = { [model] in model.attachReadiness(forTodo: $0) }
            let request = $request
            attacher.perform = { request.wrappedValue = $0 }
            attacher.select(id)
        }
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
