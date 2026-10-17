import SwiftUI

/// Settings → Terminal: text size and the terminal's own light/dark theme.
struct TerminalSettingsView: View {
    @AppStorage(TextSizeShortcuts.fontSizeKey) private var fontSize = TerminalAppearance.defaultFontSize
    @AppStorage("terminal.theme") private var themeRaw = TerminalTheme.system.rawValue

    var body: some View {
        Form {
            Section {
                Stepper(value: $fontSize, in: TerminalAppearance.fontSizeRange, step: 1) {
                    LabeledContent("Text size", value: "\(Int(fontSize)) pt")
                }
                Picker("Theme", selection: $themeRaw) {
                    ForEach(TerminalTheme.allCases, id: \.self) { theme in
                        Text(Self.name(theme)).tag(theme.rawValue)
                    }
                }
            } footer: {
                Text("Set Claude's theme with /theme to match.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func name(_ theme: TerminalTheme) -> String {
        switch theme {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Settings → Notifications: the "needs you" switch. Turning it on asks for permission (never
/// at launch); if that's refused the switch goes back off. While it's on, the push settings
/// (done alerts, quiet hours, mutes, the push state) follow below it.
struct NeedsYouSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(NotificationCenterCoordinator.enabledKey) private var needsYou = false
    @State private var refused = false

    var body: some View {
        Form {
            Section {
                Toggle("Notify me when a conversation needs me", isOn: Binding(
                    get: { needsYou },
                    set: { on in setNeedsYou(on) }
                ))
            } footer: {
                if refused {
                    Text("Notifications are turned off for this app. Turn them on in Settings.")
                }
            }
            if needsYou {
                NotificationSettingsView(todoTitles: todoTitles)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Names the muted todos in the push settings.
    private var todoTitles: [String: String] {
        Dictionary(model.store.todos.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    private func setNeedsYou(_ on: Bool) {
        needsYou = on
        refused = false
        Task {
            let accepted = await NotificationCenterCoordinator.shared.setNeedsYouEnabled(on)
            if on && !accepted {
                needsYou = false
                refused = true
            }
        }
    }
}
