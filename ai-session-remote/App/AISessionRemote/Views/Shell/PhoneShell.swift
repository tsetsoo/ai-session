#if os(iOS)
import AISessionCore
import SwiftData
import SwiftUI

/// The iPhone app: Todos, Conversations (badged with the Needs-you count), Projects and
/// Computers tabs.
/// Each tab is its own navigation stack with a large title and ⚙ for Settings; opening a todo
/// pushes its conversation full screen, without the tab bar.
///
/// On iPad in compact width the open conversation is kept in `AppModel.selectedTodoID`, so it
/// survives the swap to and from `MacShell` (see `reopenSelection`).
struct PhoneShell: View {
    enum Tab: String, Hashable {
        case todos, conversations, projects, computers
    }

    enum Route: Hashable {
        /// Opened by a tap: starts (or resumes) the conversation.
        case todo(String)
        case computer(String)
        case project(String)
        /// Shown without starting anything: a notification tap, or the Mac layout's selection
        /// pushed again after an iPad shell swap. It attaches only if the conversation runs,
        /// like a selection on the Mac.
        case reopened(String)

        var todoID: String? {
            switch self {
            case let .todo(id), let .reopened(id): id
            case .computer, .project: nil
            }
        }
    }

    /// Settings as a sheet, optionally opened on one destination.
    private struct SettingsRequest: Identifiable {
        let id = UUID()
        let initial: SettingsDestination?
    }

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var tab: Tab = .todos
    @State private var todosPath: [Route] = []
    @State private var conversationsPath: [Route] = []
    @State private var projectsPath: [Route] = []
    @State private var computersPath: [Route] = []
    @State private var filter = ConversationListView.Filter.running
    /// Once the filter is picked by hand it stays; until then it follows the default rule.
    @State private var filterChosen = false
    @State private var settings: SettingsRequest?
    @State private var showingAdd = false
    @State private var showingNewFromConversation = false
    /// `.attach` / `.detach` for a re-opened conversation's frame.
    @State private var reopenRequest: FrameRequest?

    init() {
        #if DEBUG
        // `-demoProjects` (canned projects, see TodoHubDemo) opens on the Projects tab.
        if ProcessInfo.processInfo.arguments.contains("-demoProjects") {
            _tab = State(initialValue: .projects)
        }
        // Screenshots: `-uiDemoTab todos|conversations|projects|computers`, `-uiDemoSettings
        // [page]` and `-uiDemoOpen <todo id>` (pushes that todo's conversation on the selected tab).
        guard DemoFixtures.isEnabled else { return }
        let tab = DemoFixtures.value(after: "-uiDemoTab").flatMap(Tab.init(rawValue:)) ?? .todos
        _tab = State(initialValue: tab)
        if ProcessInfo.processInfo.arguments.contains("-uiDemoSettings") {
            // An optional destination: server, sections (Sp), access, terminal, notifications.
            let initial: SettingsDestination? = switch DemoFixtures.value(after: "-uiDemoSettings") {
            case "server": .server
            case "sections": .sections(.sp)
            case "access": .access
            case "terminal": .terminal
            case "notifications": .notifications
            default: nil
            }
            _settings = State(initialValue: SettingsRequest(initial: initial))
        }
        if let todoID = DemoFixtures.value(after: "-uiDemoOpen") {
            switch tab {
            case .todos: _todosPath = State(initialValue: [.todo(todoID)])
            case .conversations: _conversationsPath = State(initialValue: [.todo(todoID)])
            case .projects: _projectsPath = State(initialValue: [.todo(todoID)])
            case .computers: _computersPath = State(initialValue: [.todo(todoID)])
            }
        }
        #endif
    }

    private var store: TodoHubStore { model.store }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $todosPath) {
                todosRoot
                    .phoneTab("Todos", openSettings: openSettings)
                    .toolbar { addMenu }
                    .navigationDestination(for: Route.self) { destination($0, path: $todosPath) }
            }
            .tabItem { Label("Todos", systemImage: "checklist") }
            .tag(Tab.todos)

            NavigationStack(path: $conversationsPath) {
                conversationsRoot
                    .phoneTab("Conversations", openSettings: openSettings)
                    .navigationDestination(for: Route.self) { destination($0, path: $conversationsPath) }
            }
            .tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
            .badge(model.board.needsYou.count)
            .tag(Tab.conversations)

            NavigationStack(path: $projectsPath) {
                projectsRoot
                    .phoneTab("Projects", openSettings: openSettings)
                    .navigationDestination(for: Route.self) { destination($0, path: $projectsPath) }
            }
            .tabItem { Label("Projects", systemImage: "folder") }
            .tag(Tab.projects)

            NavigationStack(path: $computersPath) {
                computersRoot
                    .phoneTab("Computers", openSettings: openSettings)
                    .navigationDestination(for: Route.self) { destination($0, path: $computersPath) }
            }
            .tabItem { Label("Computers", systemImage: "desktopcomputer") }
            .tag(Tab.computers)
        }
        .tint(DS.accent)
        .environment(\.openAppSettings) { openSettings($0) }
        .sheet(item: $settings) { request in
            SettingsView(initial: request.initial)
        }
        .sheet(isPresented: $showingAdd) {
            AddTodoSheet(store: store)
                .tint(DS.accent)
        }
        .sheet(isPresented: $showingNewFromConversation) {
            NewTodoFromConversationSheet(store: store)
                .tint(DS.accent)
        }
        .todoStoreErrorAlert(store)
        .onAppear {
            applyDefaultFilter()
            reopenSelection()
            #if DEBUG
            if projectsPath.isEmpty, let id = ProjectsDemo.projectPage(store) {
                projectsPath = [.project(id)]
            }
            #endif
        }
        .onChange(of: tab) { _, _ in applyDefaultFilter() }
        .onChange(of: openTodoID) { _, id in model.selectedTodoID = id }
        // A tapped "needs you" notification (routed by AppModel).
        .onChange(of: model.pendingOpenTodoID, initial: true) { _, todoID in
            guard let todoID else { return }
            model.pendingOpenTodoID = nil
            openFromNotification(todoID)
        }
        // The Home-screen "New Todo" quick action. The I section's title field takes the focus.
        .onChange(of: model.quickAddFocusRequested, initial: true) { _, requested in
            guard requested else { return }
            guard isConfigured else {
                // No list, no field: drop it so it can't grab focus later.
                model.quickAddFocusRequested = false
                return
            }
            tab = .todos
            todosPath = []
        }
        .task { await model.startSync() }
        // One listing for this shell. The first pass (still 0) lists every computer; a later
        // bump lists only computers whose conversations changed after their listing.
        .task(id: model.automaticLivenessID(hostIDs: hosts.map(\.id))) {
            let scope: AppModel.LivenessScope = model.relistRequests == 0 ? .full : .stale
            await model.refreshLiveness(hosts: hosts, scope: scope)
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private var todosRoot: some View {
        if !isConfigured {
            notConfigured
        } else if store.todos.isEmpty && !store.hasLoadedOnce {
            ProgressView()
        } else {
            TodoListView(sections: TodoSection.allCases, quickAddSection: .i) {
                todosPath.append(.todo($0.id))
            }
        }
    }

    @ViewBuilder
    private var conversationsRoot: some View {
        if !isConfigured {
            notConfigured
        } else {
            ConversationListView(filter: Binding(
                get: { filter },
                set: { filter = $0; filterChosen = true }
            )) { conversationsPath.append(.todo($0.id)) }
        }
    }

    @ViewBuilder
    private var projectsRoot: some View {
        if !isConfigured {
            notConfigured
        } else {
            ProjectsList(store: store, route: Route.project) { projectsPath.append(.project($0)) }
        }
    }

    @ViewBuilder
    private var computersRoot: some View {
        if !isConfigured {
            notConfigured
        } else {
            ComputerListView { computersPath.append(.computer($0.id)) }
        }
    }

    private var notConfigured: some View {
        ContentUnavailableView {
            Label("Connect to your todo server", systemImage: "checklist")
        } description: {
            Text("Enter the server address and API token to see your todos.")
        } actions: {
            Button("Open Settings") { openSettings(.server) }
                .buttonStyle(AccentButtonStyle())
        }
    }

    @ToolbarContentBuilder
    private var addMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            // Tap: new todo. Hold: new todo from an existing conversation.
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
                Image(systemName: "plus")
            } primaryAction: {
                showingAdd = true
            }
            .accessibilityLabel("Add Todo")
            .disabled(!isConfigured || store.isOffline)
        }
    }

    // MARK: Navigation

    @ViewBuilder
    private func destination(_ route: Route, path: Binding<[Route]>) -> some View {
        switch route {
        case let .todo(id):
            if let todo = store.todos.first(where: { $0.id == id }) {
                TodoConversationScreen(todo: todo, store: store) {
                    if path.wrappedValue.last == route { path.wrappedValue.removeLast() }
                }
                .toolbar(.hidden, for: .tabBar)
            } else {
                ContentUnavailableView("Todo Not Found", systemImage: "checklist")
            }
        case let .reopened(id):
            if let todo = store.todos.first(where: { $0.id == id }) {
                ConversationDetail(todo: todo, request: $reopenRequest) {
                    if path.wrappedValue.last == route { path.wrappedValue.removeLast() }
                }
                .toolbar(.hidden, for: .tabBar)
            } else {
                ContentUnavailableView("Todo Not Found", systemImage: "checklist")
            }
        case let .computer(id):
            if let computer = store.computers.first(where: { $0.id == id }) {
                ComputerDetailView(computer: computer) { path.wrappedValue.append(.todo($0.id)) }
            } else {
                ContentUnavailableView("Computer Not Found", systemImage: "desktopcomputer")
            }
        case let .project(id):
            ProjectDetailView(projectId: id, store: store) { path.wrappedValue.append(.todo($0.id)) }
        }
    }

    /// A notification tap shows the conversation on the Conversations tab, in place of what
    /// that tab had open. It attaches only if the conversation runs, never starts one.
    private func openFromNotification(_ todoID: String) {
        model.selectedConversationID = store.conversationToOpen(forTodo: todoID)
        tab = .conversations
        conversationsPath = [.reopened(todoID)]
    }

    private var currentPath: Binding<[Route]> {
        switch tab {
        case .todos: $todosPath
        case .conversations: $conversationsPath
        case .projects: $projectsPath
        case .computers: $computersPath
        }
    }

    /// The conversation on screen, if any: the Mac layout selects it after an iPad shell swap.
    private var openTodoID: String? {
        currentPath.wrappedValue.last?.todoID
    }

    /// After an iPad shell swap (regular → compact width), the conversation the Mac layout had
    /// selected is pushed again. It never starts one: it attaches only if it already runs.
    private func reopenSelection() {
        guard let id = model.selectedTodoID, store.todos.contains(where: { $0.id == id }) else { return }
        let paths = todosPath + conversationsPath + projectsPath + computersPath
        guard !paths.contains(where: { $0.todoID == id }) else { return }
        currentPath.wrappedValue.append(.reopened(id))
    }

    private func openSettings(_ destination: SettingsDestination?) {
        settings = SettingsRequest(initial: destination)
    }

    /// Needs you when something needs you, else Running, until the filter is picked by hand.
    private func applyDefaultFilter() {
        guard tab == .conversations, !filterChosen else { return }
        filter = .initial(needsYouCount: model.board.needsYou.count)
    }

    private var isConfigured: Bool { model.isConfigured }
}

private extension View {
    /// A tab's root: large title and ⚙ on the leading side.
    func phoneTab(_ title: String, openSettings: @escaping (SettingsDestination?) -> Void) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        openSettings(nil)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
    }
}
#endif
