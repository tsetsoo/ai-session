import AISessionCore
import SwiftUI

/// Navigation value for a project page.
struct ProjectRoute: Hashable {
    let id: String
}

/// The Projects tab: suggested folders on top, then projects grouped by computer.
struct ProjectsView: View {
    let store: TodoHubStore
    @State private var path: [ProjectRoute] = []
    @State private var editor: ProjectEditorSheet.Mode?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Projects")
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
                .navigationDestination(for: ProjectRoute.self) { route in
                    ProjectDetailView(projectId: route.id, store: store)
                }
        }
        #if DEBUG
        .onAppear {
            // `-demoProjects -demoProjectPage`: open the first demo project for screenshots.
            if ProcessInfo.processInfo.arguments.contains("-demoProjectPage"), path.isEmpty,
               let id = store.demo?.projects.last?.id {
                path = [ProjectRoute(id: id)]
            }
        }
        #endif
        .sheet(item: $editor) { mode in
            ProjectEditorSheet(mode: mode, store: store) { created in
                path.append(ProjectRoute(id: created.id))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !store.isConfigured {
            ContentUnavailableView {
                Label("Connect to your todo server", systemImage: "folder")
            } description: {
                Text("Set up the server URL and API token in the Todos tab to see your projects.")
            }
        } else if store.projects.isEmpty && !store.hasLoadedOnce {
            ProgressView()
        } else {
            List {
                if store.isOffline {
                    Label("Offline — read only", systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
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
                            NavigationLink(value: ProjectRoute(id: project.id)) {
                                ProjectRow(project: project)
                            }
                        }
                    } header: {
                        Label(group.computer.name, systemImage: "desktopcomputer")
                    }
                }
            }
            .listStyle(.insetGrouped)
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
