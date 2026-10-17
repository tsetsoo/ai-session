#if os(iOS)
import AISessionCore
import SwiftUI

/// The iPhone app: Todos, Conversations (badged with the Needs-you count) and Computers tabs.
/// Each tab is its own navigation stack with a large title and ⚙ for Settings; opening a todo
/// pushes its conversation full screen, without the tab bar.
struct PhoneShell: View {
    enum Tab: String, Hashable {
        case todos, conversations, computers
    }

    enum Route: Hashable {
        case todo(String)
        case computer(String)
    }

    /// Settings as a sheet, optionally opened on one destination.
    private struct SettingsRequest: Identifiable {
        let id = UUID()
        let initial: SettingsDestination?
    }

    @Environment(AppModel.self) private var model
    @AppStorage(QuickAdd.sectionKey) private var quickAddSection = TodoSection.i.rawValue
    @State private var tab: Tab = .todos
    @State private var todosPath: [Route] = []
    @State private var conversationsPath: [Route] = []
    @State private var computersPath: [Route] = []
    @State private var filter = ConversationListView.Filter.running
    /// Once the filter is picked by hand it stays; until then it follows the default rule.
    @State private var filterChosen = false
    @State private var settings: SettingsRequest?
    @State private var showingAdd = false
    @State private var showingNewFromConversation = false

    init() {
        #if DEBUG
        // Screenshots: `-uiDemoTab todos|conversations|computers`, `-uiDemoSettings [page]` and
        // `-uiDemoOpen <todo id>` (pushes that todo's conversation on the selected tab).
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
            AddTodoSheet(section: QuickAdd.section(from: quickAddSection)) { section, title in
                Task { await store.createTodo(section: section, title: title) }
            }
            .tint(DS.accent)
        }
        .sheet(isPresented: $showingNewFromConversation) {
            NewTodoFromConversationSheet(store: store)
                .tint(DS.accent)
        }
        .onAppear { applyDefaultFilter() }
        .onChange(of: tab) { _, _ in applyDefaultFilter() }
        .task { await model.startSync() }
    }

    // MARK: Tabs

    @ViewBuilder
    private var todosRoot: some View {
        if !isConfigured {
            notConfigured
        } else if store.todos.isEmpty && !store.hasLoadedOnce {
            ProgressView()
        } else {
            TodoListView(sections: TodoSection.allCases) { todosPath.append(.todo($0.id)) }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    QuickAddBar()
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
        case let .computer(id):
            if let computer = store.computers.first(where: { $0.id == id }) {
                ComputerDetailView(computer: computer) { path.wrappedValue.append(.todo($0.id)) }
            } else {
                ContentUnavailableView("Computer Not Found", systemImage: "desktopcomputer")
            }
        }
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
