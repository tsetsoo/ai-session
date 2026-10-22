import AISessionCore
import SwiftUI

#if DEBUG
enum ProjectsDemo {
    /// `-demoProjects -demoProjectPage`: the demo project the shells open for screenshots.
    @MainActor
    static func projectPage(_ store: TodoHubStore) -> String? {
        guard ProcessInfo.processInfo.arguments.contains("-demoProjectPage") else { return nil }
        return store.demo?.projects.last?.id
    }
}
#endif

/// Suggested folders on top, then projects grouped by computer, with + New Project. In a
/// navigation stack rows link to the host's `Route` for a project; with a `selection` (the
/// Mac's list column) they select instead.
struct ProjectsList<Route: Hashable>: View {
    let store: TodoHubStore
    /// The selected project id; when set, rows select instead of linking.
    var selection: Binding<String?>?
    let route: (String) -> Route
    /// A project was just created: show it.
    let onCreated: (String) -> Void
    @State private var editor: ProjectEditorSheet.Mode?

    init(store: TodoHubStore, route: @escaping (String) -> Route, onCreated: @escaping (String) -> Void) {
        self.store = store
        self.route = route
        self.onCreated = onCreated
    }

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editor = .create(nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Project")
                    .disabled(!store.isConfigured || store.isOffline)
                }
            }
            .refreshable { await store.refresh() }
            .sheet(item: $editor) { mode in
                ProjectEditorSheet(mode: mode, store: store) { created in
                    onCreated(created.id)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !store.isConfigured {
            ServerNotConfiguredView(systemImage: "folder",
                                    description: "Enter the server address and API token to see your projects.")
        } else if store.projects.isEmpty && !store.hasLoadedOnce {
            ProgressView()
        } else {
            if let selection {
                List(selection: selection) { rows }
                    .listStyle(.insetGrouped)
            } else {
                List { rows }
                    .listStyle(.insetGrouped)
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        // Offline (with Retry) or a rejected token, like the other lists.
        ListStatusBanner(store: store)
        if !store.suggestions.isEmpty && !store.isOffline {
            suggestionsSection
        }
        if store.projects.isEmpty {
            Section {
                Text(store.suggestions.isEmpty
                    ? "No projects yet. A project is a folder on one of your computers; conversations in it are grouped automatically."
                    : "No projects yet. Pick a suggested folder above, or add one with +.")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(store.projectsByComputer, id: \.computer.id) { group in
            Section {
                ForEach(group.projects) { project in
                    if selection != nil {
                        ProjectRow(project: project)
                            .tag(project.id)
                    } else {
                        NavigationLink(value: route(project.id)) {
                            ProjectRow(project: project)
                        }
                    }
                }
            } header: {
                Label(group.computer.name, systemImage: "desktopcomputer")
            }
        }
    }

    private var suggestionsSection: some View {
        Section {
            ForEach(store.suggestions) { suggestion in
                Button {
                    editor = .create(suggestion)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.name)
                                .foregroundStyle(.primary)
                            Text(suggestion.folder)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            HStack(spacing: 4) {
                                Text(suggestion.computer.name)
                                Text("· \(suggestion.sessions) conversation\(suggestion.sessions == 1 ? "" : "s")")
                                if let ago = AppTheme.relativeTime(from: suggestion.lastActivityDate) {
                                    Text("· \(ago)")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Suggested")
        } footer: {
            Text("Folders with conversations that aren't in a project yet. Tap one to create it.")
        }
    }
}

extension ProjectsList where Route == String {
    /// Rows select a project id (the Mac's list column); a new project gets selected.
    init(store: TodoHubStore, selection: Binding<String?>) {
        self.store = store
        self.selection = selection
        self.route = { $0 }
        self.onCreated = { selection.wrappedValue = $0 }
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(project.name)
                if !project.digestEnabled {
                    Image(systemName: "text.badge.xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Memories not fed into conversations")
                }
            }
            Text(project.folder)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            HStack(spacing: 4) {
                Text("\(project.openTodos) open todo\(project.openTodos == 1 ? "" : "s")")
                Text("· \(project.memories) memor\(project.memories == 1 ? "y" : "ies")")
                if let ago = AppTheme.relativeTime(from: project.lastActivityDate) {
                    Text("· \(ago)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
