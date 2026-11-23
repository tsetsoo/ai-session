import SwiftUI

/// Settings → Appearance: the app-wide theme (Standard, or a cyberpunk skin).
struct AppearanceSettingsView: View {
    var body: some View {
        @Bindable var store = SkinStore.shared
        Form {
            Section {
                Picker("App theme", selection: $store.skin) {
                    ForEach(AppSkin.allCases) { skin in
                        Text(skin.displayName).tag(skin)
                    }
                }
            } footer: {
                Text("Changes the whole app, its icon and its sounds.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

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
                // A skin brings its own terminal colours.
                if SkinStore.shared.skin == .standard {
                    Picker("Theme", selection: $themeRaw) {
                        ForEach(TerminalTheme.allCases, id: \.self) { theme in
                            Text(Self.name(theme)).tag(theme.rawValue)
                        }
                    }
                }
            } footer: {
                if SkinStore.shared.skin == .standard {
                    Text("Set Claude's theme with /theme to match.")
                } else {
                    Text("The \(SkinStore.shared.skin.displayName) theme sets the terminal colours. Set Claude's theme to dark with /theme.")
                }
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
            #if os(macOS)
            MacAttentionSettingsSection()
            #endif
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
