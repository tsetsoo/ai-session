import SwiftUI

/// Top level. iPhone and compact-width iPad: `PhoneShell`. Everything else keeps the Todos and
/// Hosts tabs until the Mac shell (PR 5).
struct RootView: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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
        } else if DemoFixtures.isEnabled, DemoFixtures.screen == "frame" {
            DemoFrameScreen()
        } else if ProcessInfo.processInfo.arguments.contains("-demoConversationPicker") {
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
        TabView {
            TodosView()
                .tabItem { Label("Todos", systemImage: "checklist") }
            HostsListView()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
        }
    }
}
