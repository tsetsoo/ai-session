import SwiftUI

/// Top level. iPhone and compact-width iPad: `PhoneShell`. Everything else keeps the Todos,
/// Projects and Hosts tabs until the Mac shell (PR 5). One hub store, owned by `AppModel`.
struct RootView: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Environment(AppModel.self) private var model
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
        } else if DemoFixtures.isEnabled, DemoFixtures.screen == "frame" {
            DemoFrameScreen()
        } else if arguments.contains("-demoConversationPicker") {
            ConversationPickerDemo()
        } else {
            main
        }
        #else
        main
        #endif
    }

    @ViewBuilder
    private var main: some View {
        #if os(iOS)
        // An iPhone stays on the phone shell in landscape too, where the larger models report a
        // regular width; swapping shells on rotation would drop the open conversation.
        if horizontalSizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone || Self.forcesPhoneShell {
            PhoneShell()
        } else {
            tabs
        }
        #else
        tabs
        #endif
    }

    /// `-uiDemo` screenshots always show the iPhone shell on iOS.
    private static var forcesPhoneShell: Bool {
        #if DEBUG
        DemoFixtures.isEnabled
        #else
        false
        #endif
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            TodosView()
                .tabItem { Label("Todos", systemImage: "checklist") }
                .tag(Tab.todos)
            ProjectsView(store: model.store)
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
        .onAppear {
            #if DEBUG
            if model.store.demo != nil { tab = .projects }
            #endif
        }
        .task { await startHub() }
    }

    private func startHub() async {
        let store = model.store
        #if DEBUG
        // Demo data never touches the network.
        if DemoFixtures.isEnabled || store.demo != nil { return }
        #endif
        guard store.isConfigured else { return }
        await store.refresh()
        store.startLiveUpdates()
    }
}
