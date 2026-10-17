import SwiftUI

/// Top level: Todos (hub-backed, each todo opens its AI conversation), Projects (folders that
/// group todos, conversations and memories) and Hosts (direct SSH). Todos and Projects share
/// one hub store.
struct RootView: View {
    @State private var store = TodoHubStore()
    @State private var tab = Tab.todos

    enum Tab: Hashable {
        case todos, projects, hosts
    }

    var body: some View {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if DemoFixtures.isEnabled, DemoFixtures.screen == "terminal" {
            NavigationStack {
                TerminalScreen(
                    hostConfig: DemoFixtures.config,
                    mode: .attach("demo"),
                    title: "Fix the rate import",
                    onKill: {},
                    makeTransport: { _, _ in DemoTransport() }
                )
            }
        } else if arguments.contains("-demoConversationPicker") {
            ConversationPickerDemo()
        } else if arguments.contains("-demoProjects") {
            tabs
                .onAppear {
                    store.loadDemo(.sample)
                    tab = .projects
                }
        } else {
            tabs.task { await startHub() }
        }
        #else
        tabs.task { await startHub() }
        #endif
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            TodosView(store: store)
                .tabItem { Label("Todos", systemImage: "checklist") }
                .tag(Tab.todos)
            ProjectsView(store: store)
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag(Tab.projects)
            HostsListView()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
                .tag(Tab.hosts)
        }
        // A tapped notification opens its todo's conversation in the Todos tab.
        .onReceive(NotificationCenter.default.publisher(for: .todoNotificationOpened)) { _ in
            tab = .todos
        }
    }

    private func startHub() async {
        guard store.isConfigured else { return }
        await store.refresh()
        store.startLiveUpdates()
    }
}
