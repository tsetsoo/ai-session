import AISessionCore
import SwiftUI

/// Session queues and the computer/project hierarchy for Mac and regular-width iPad.
struct SidebarView: View {
    @Binding var selection: AppModel.SidebarItem?
    /// Settings on iPad; the Mac opens its Settings scene instead.
    let openSettings: () -> Void
    let addProject: (String) -> Void
    @State private var collapsedComputers: Set<String> = []

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(get: { !collapsedComputers.contains(id) }, set: { expanded in
            if expanded { collapsedComputers.remove(id) }
            else { collapsedComputers.insert(id) }
        })
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openAppSettings) private var openAppSettings

    private var store: TodoHubStore { model.store }

    var body: some View {
        let board = model.board
        let counts = SidebarCounts(board: board, computers: store.computers)
        let projects = Dictionary(uniqueKeysWithValues: store.projectsByComputer.map { ($0.computer.id, $0.projects) })
        let urgentTodos = Set(board.needsYou.map(\.todoId))
        let urgentProjects = Set(store.todos.filter { urgentTodos.contains($0.id) }.compactMap(\.projectId))
        List(selection: $selection) {
            Section {
                SidebarRow(title: "Needs you", systemImage: "exclamationmark.circle", iconTint: DS.accent,
                           count: counts.needsYou, countTint: DS.accent)
                    .tag(AppModel.SidebarItem.needsYou)
                SidebarRow(title: "To review", systemImage: "checkmark.circle", count: counts.review)
                    .tag(AppModel.SidebarItem.review)
                SidebarRow(title: "Working", systemImage: "bolt", count: counts.working)
                    .tag(AppModel.SidebarItem.working)
            }
            SidebarRow(title: "Todos", systemImage: "checkmark.square", count: 0)
                .tag(AppModel.SidebarItem.todos)
            if !counts.computers.isEmpty {
                Section("Computers") {
                    ForEach(counts.computers, id: \.id) { row in
                        DisclosureGroup(isExpanded: expansion(for: row.id)) {
                            ForEach(projects[row.id] ?? []) { project in
                                SidebarRow(title: project.name, systemImage: "folder", count: project.openTodos,
                                           showsDot: urgentProjects.contains(project.id))
                                    .tag(AppModel.SidebarItem.project(project.id))
                                    .contextMenu {
                                        Button("Project Details", systemImage: "info.circle") {
                                            selection = .project(project.id)
                                            model.selectedProjectID = project.id
                                        }
                                    }
                            }
                        } label: {
                            SidebarRow(title: row.name, systemImage: "desktopcomputer", count: row.open)
                                .contextMenu {
                                    Button("Add Project", systemImage: "plus") { addProject(row.id) }
                                        .disabled(!store.canCreateProject(on: row.id))
                                }
                        }
                        .tag(AppModel.SidebarItem.computer(row.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, item in
            if case let .project(id) = item, let project = store.project(id: id) {
                collapsedComputers.remove(project.computer.id)
            }
        }
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
                let label = Label {
                    Text(line.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: line.systemImage)
                        .foregroundStyle(line.kind == .tokenRejected ? DS.accent : Color.secondary)
                }
                .foregroundStyle(.secondary)
                // A problem only Settings fixes: the line is the way there.
                if line.kind == .tokenRejected || line.kind == .notConfigured, let openAppSettings {
                    Button { openAppSettings(.server) } label: {
                        label.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open Settings → Server")
                    .accessibilityHint("Opens the server settings")
                } else {
                    label.accessibilityElement(children: .combine)
                }
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
