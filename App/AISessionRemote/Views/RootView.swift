import SwiftUI

/// Top level: Todos (hub-backed, each todo opens its AI conversation) and Hosts (direct SSH).
struct RootView: View {
    private enum Tab { case todos, hosts }
    @State private var tab = Tab.todos

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demoConversationPicker") {
            ConversationPickerDemo()
        } else {
            tabs
        }
        #else
        tabs
        #endif
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            TodosView()
                .tabItem { Label("Todos", systemImage: "checklist") }
                .tag(Tab.todos)
            HostsListView()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
                .tag(Tab.hosts)
        }
        // A tapped notification opens its todo's conversation in the Todos tab.
        .onReceive(NotificationCenter.default.publisher(for: .todoNotificationOpened)) { _ in
            tab = .todos
        }
    }
}
