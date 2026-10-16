import SwiftUI

/// Top level: Todos (hub-backed, each todo opens its AI conversation) and Hosts (direct SSH).
struct RootView: View {
    var body: some View {
        TabView {
            TodosView()
                .tabItem { Label("Todos", systemImage: "checklist") }
            HostsListView()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
        }
    }
}
