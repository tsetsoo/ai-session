import AISessionCore
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
    @AppStorage(QuickAdd.sectionKey) private var quickAddSection = TodoSection.i.rawValue
    @State private var query = ""
    @State private var settings: SettingsRequest?
    @State private var showingAdd = false

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
        .sheet(item: $settings) { request in
            SettingsView(initial: request.initial)
        }
        .sheet(isPresented: $showingAdd) {
            AddTodoSheet(section: addSection) { section, title in
                Task { await store.createTodo(section: section, title: title) }
            }
            .tint(DS.accent)
        }
        .onChange(of: model.sidebarSelection) { _, _ in query = "" }
        .onAppear(perform: applyInitialSelection)
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label("New Todo", systemImage: "plus")
                }
                .help("New Todo")
                .disabled(!model.isConfigured || store.isOffline)
            }
        }
    }

    @ViewBuilder
    private func list(for item: AppModel.SidebarItem) -> some View {
        switch item {
        case .needsYou:
            ConversationListView(filter: .constant(.needsYou), showsFilterPicker: false,
                                 query: query, selection: selection, onOpen: select)
        case .runningNow:
            ConversationListView(filter: .constant(.running), showsFilterPicker: false,
                                 showsShortcuts: Self.showsShortcuts, query: query, selection: selection,
                                 onOpen: select)
        case let .section(section):
            TodoListView(sections: [section], query: query, selection: selection, onOpen: select)
        case let .computer(id):
            if let computer = store.computers.first(where: { $0.id == id }) {
                // Other Sessions, On This Computer and Open Shell push inside the list column,
                // leaving the conversation in the detail column alone.
                NavigationStack {
                    ComputerDetailView(computer: computer, query: query, selection: selection, onOpen: select)
                        // The stack hides the column's search field; offer it again inside.
                        .searchable(text: $query, prompt: "Search")
                }
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
        if let id = model.selectedTodoID, let todo = store.todos.first(where: { $0.id == id }) {
            // 5.2: debounce selection by 150 ms; ⏎ and double-click start; pop-out windows.
            // Until then selection only attaches to a running conversation, never starts one.
            TodoConversationScreen(todo: todo, store: store, onAppear: .attachIfRunning) {
                model.selectedTodoID = nil
            }
            .id(todo.id)
        } else {
            ContentUnavailableView {
                Label("Select a conversation", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("⌘K to jump · ⌘N new todo")
            }
        }
    }

    // MARK: Selection

    private var selection: Binding<String?> {
        Binding(get: { model.selectedTodoID }, set: { model.selectedTodoID = $0 })
    }

    /// "Open" from a row's context menu: select it.
    private func select(_ todo: Todo) {
        model.selectedTodoID = todo.id
    }

    private func applyInitialSelection() {
        #if DEBUG
        if DemoFixtures.isEnabled {
            // `-uiDemoSidebar needsyou|running|Sp|I|Si|P|computer:<id>` and `-uiDemoOpen <todo id>`.
            model.sidebarSelection = DemoFixtures.value(after: "-uiDemoSidebar")
                .flatMap(AppModel.SidebarItem.init(demoArgument:)) ?? .runningNow
            model.selectedTodoID = DemoFixtures.value(after: "-uiDemoOpen") ?? model.board.runningNow.first?.todoId
            #if os(macOS)
            // Launched from a script, the window would stay inactive and draw its selection grey.
            NSApplication.shared.activate(ignoringOtherApps: true)
            #endif
            return
        }
        #endif
        if model.sidebarSelection == nil { model.sidebarSelection = .runningNow }
    }
}

#if DEBUG
extension AppModel.SidebarItem {
    /// `-uiDemoSidebar` values: needsyou, running, a section code, or computer:<id>.
    init?(demoArgument: String) {
        switch demoArgument {
        case "needsyou": self = .needsYou
        case "running": self = .runningNow
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
