import AISessionCore
import SwiftUI

extension EnvironmentValues {
    /// Opens Settings (at a destination) from deep inside a screen, e.g. the token banner.
    /// Nil where no shell provides it.
    @Entry var openAppSettings: ((SettingsDestination) -> Void)?
}

/// Settings, shown as a sheet: Todo server, Sections & computers, Access & keys (the only place
/// SSH words appear), Terminal and Notifications.
///
/// The server, sections and access screens each own a navigation stack, so they open as sheets
/// over this one rather than being pushed. Given one of them as `initial` (a fix from the
/// conversation frame), Settings opens straight on that screen and closes with it.
struct SettingsView: View {
    let initial: SettingsDestination?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Page]
    @State private var sheet: Sheet?

    enum Page: Hashable {
        case terminal, notifications
    }

    private enum Sheet: String, Identifiable {
        case server, sections, access
        var id: String { rawValue }
    }

    init(initial: SettingsDestination? = nil) {
        self.initial = initial
        switch initial {
        case .terminal?: _path = State(initialValue: [.terminal])
        case .notifications?: _path = State(initialValue: [.notifications])
        default: _path = State(initialValue: [])
        }
    }

    var body: some View {
        Group {
            switch initial {
            case .server?:
                serverSettings
            case let .sections(section)?:
                ComputersView(store: model.store, editing: section)
            case .access?:
                AccessSettings()
            case .terminal?, .notifications?, nil:
                root
            }
        }
        // A sheet doesn't pick up the shell's tint.
        .tint(DS.accent)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
    }

    private var root: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    SettingsSheetRow(title: "Todo server", systemImage: "server.rack", value: serverName) {
                        sheet = .server
                    }
                    SettingsSheetRow(title: "Sections & computers", systemImage: "desktopcomputer") {
                        sheet = .sections
                    }
                    .disabled(!model.store.isConfigured)
                } footer: {
                    if !model.store.isConfigured {
                        Text("Sections and computers live on the todo server. Connect to it first.")
                    }
                }
                Section {
                    SettingsSheetRow(title: "Access & keys", systemImage: "key") {
                        sheet = .access
                    }
                } footer: {
                    Text("How this device signs in to your computers.")
                }
                Section {
                    NavigationLink(value: Page.terminal) {
                        Label("Terminal", systemImage: "terminal")
                    }
                    NavigationLink(value: Page.notifications) {
                        Label("Notifications", systemImage: "bell")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .terminal: TerminalSettingsView()
                case .notifications: NeedsYouSettingsView()
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .server: serverSettings
                case .sections: ComputersView(store: model.store)
                case .access: AccessSettings()
                }
            }
            .tint(DS.accent)
        }
    }

    private var serverSettings: some View {
        let store = model.store
        return TodoHubSettingsView { Task { await store.reconnect() } }
    }

    /// The server's host name, or "Not set up".
    private var serverName: String {
        guard model.store.isConfigured else { return "Not set up" }
        return TodoHubClient.baseURL(from: TodoHubSettings.baseURLString)?.host() ?? "Not set up"
    }
}

/// A Settings row that opens a sheet, drawn like a navigation row.
private struct SettingsSheetRow: View {
    let title: String
    let systemImage: String
    var value: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.spacing.s) {
                // Text in the primary colour, the icon tinted like a navigation row's.
                Label {
                    Text(title).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(.tint)
                }
                Spacer(minLength: DS.spacing.s)
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                #if os(iOS)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                #endif
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The saved hosts (SSH access and keys) with a Done button: `HostsListView` hides its own
/// navigation bar.
struct AccessSettings: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, DS.spacing.l)
            .padding(.top, DS.spacing.m)
            HostsListView()
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }
}
