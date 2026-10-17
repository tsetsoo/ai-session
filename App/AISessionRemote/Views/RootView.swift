import SwiftUI

/// Top level: Todos (hub-backed, each todo opens its AI conversation) and Hosts (direct SSH).
struct RootView: View {
    var body: some View {
        #if DEBUG
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
        } else if ProcessInfo.processInfo.arguments.contains("-demoConversationPicker") {
            ConversationPickerDemo()
        } else {
            tabs
        }
        #else
        tabs
        #endif
    }

    private var tabs: some View {
        TabView {
            TodosView()
                .tabItem { Label("Todos", systemImage: "checklist") }
            HostsListView()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
        }
    }
}
