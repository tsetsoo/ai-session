import AISessionCore
import SwiftUI

/// The Mac (and regular-width iPad) sidebar: Needs you and Running now, the todo sections,
/// Projects, then the computers, with the sync line and Settings at the bottom.
struct SidebarView: View {
    @Binding var selection: AppModel.SidebarItem?
    /// Settings on iPad; the Mac opens its Settings scene instead.
    let openSettings: () -> Void

    @Environment(AppModel.self) private var model

    private var store: TodoHubStore { model.store }

    var body: some View {
        let counts = SidebarCounts(board: model.board, computers: store.computers)
        List(selection: $selection) {
            Section {
                SidebarRow(title: "Needs you", systemImage: "exclamationmark.circle", iconTint: DS.accent,
                           count: counts.needsYou, countTint: DS.accent)
                    .tag(AppModel.SidebarItem.needsYou)
                SidebarRow(title: "Running now", systemImage: "bolt", count: counts.runningNow)
                    .tag(AppModel.SidebarItem.runningNow)
            }
            Section("Todos") {
                ForEach(counts.sections, id: \.section) { row in
                    SidebarRow(title: row.section.rawValue, systemImage: "checkmark.square",
                               count: row.openTodos, showsDot: row.needsYou)
                        .tag(AppModel.SidebarItem.section(row.section))
                }
            }
            Section {
                SidebarRow(title: "Projects", systemImage: "folder", count: 0)
                    .tag(AppModel.SidebarItem.projects)
            }
            if !counts.computers.isEmpty {
                Section("Computers") {
                    ForEach(counts.computers, id: \.id) { row in
                        SidebarRow(title: row.name, systemImage: "desktopcomputer", count: row.running)
                            .tag(AppModel.SidebarItem.computer(row.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.spacing.s) {
            Divider()
            TimelineView(.everyMinute) { context in
                let line = SyncLine.make(
                    isConfigured: model.isConfigured,
                    hasLoadedOnce: store.hasLoadedOnce,
                    isOffline: store.isOffline,
                    tokenRejected: store.tokenRejected,
                    lastSync: store.cachedAt,
                    now: context.date
                )
                Label {
                    Text(line.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: line.systemImage)
                        .foregroundStyle(line.kind == .tokenRejected ? DS.accent : Color.secondary)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, DS.spacing.m)
            settingsButton
                .padding(.horizontal, DS.spacing.m)
                .padding(.bottom, DS.spacing.m)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var settingsButton: some View {
        let label = HStack {
            Label("Settings", systemImage: "gearshape")
            Spacer()
            #if os(macOS)
            Text("⌘,").accessibilityHidden(true)
            #endif
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        #if os(macOS)
        SettingsLink { label }
            .buttonStyle(.plain)
        #else
        Button(action: openSettings) { label }
            .buttonStyle(.plain)
        #endif
    }
}

/// One sidebar row: icon, title, an optional accent dot and a trailing count (none for zero).
private struct SidebarRow: View {
    let title: String
    let systemImage: String
    var iconTint: Color?
    let count: Int
    var countTint: Color?
    var showsDot = false

    var body: some View {
        HStack(spacing: DS.spacing.s) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(iconTint ?? Color.secondary)
            }
            Spacer(minLength: DS.spacing.s)
            if showsDot {
                Circle()
                    .fill(DS.accent)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("A conversation needs you")
            }
            if let label = SidebarCounts.label(count) {
                Text(label)
                    .font(.callout.weight(countTint == nil ? .regular : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(countTint ?? Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
