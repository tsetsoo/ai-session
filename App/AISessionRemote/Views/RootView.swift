import SwiftUI

/// Top level. iPhone: `PhoneShell`. iPad: `MacShell` in regular width, `PhoneShell` in compact
/// width (Split View, Slide Over). The Mac: `MacShell`.
///
/// On iPad the shells swap as the width changes. The open conversation lives on as
/// `AppModel.selectedTodoID`: the Mac layout selects it, the phone shell pushes its frame.
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
        // regular width.
        if UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact || Self.forcesCompactWidth {
            PhoneShell()
        } else {
            MacShell()
        }
        #else
        MacShell()
        #endif
    }

    #if os(iOS)
    /// `-uiDemoCompact`: the iPad's compact-width routing, as in Split View or Slide Over (which
    /// the Simulator can't script). Only the routing: the window itself stays full width.
    private static var forcesCompactWidth: Bool {
        #if DEBUG
        DemoFixtures.isEnabled && ProcessInfo.processInfo.arguments.contains("-uiDemoCompact")
        #else
        false
        #endif
    }
    #endif
}
