import AISessionCore
import SwiftUI

/// "Project ▸" submenu for a todo's context menu. A todo always has a project, so the menu
/// only offers projects, each labeled with its section code.
struct TodoProjectMenu: View {
    let todo: Todo
    let store: TodoHubStore

    var body: some View {
        Menu {
            ForEach(store.projectsByComputer, id: \.computer.id) { group in
                Section(group.computer.name) {
                    ForEach(group.projects) { project in
                        Button {
                            Task { await store.setProject(project.id, for: todo) }
                        } label: {
                            let title = TodoProjectMenuTitle.row(section: project.section, name: project.name)
                            if todo.projectId == project.id {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Project", systemImage: "folder")
        }
        .disabled(store.isOffline || store.projects.isEmpty)
    }
}

/// "Move to Project ▸" and "Match Automatically" for a conversation on a project page.
/// Only projects on the conversation's own computer are offered (the hub rejects others).
struct SessionProjectMenu: View {
    let session: HubSession
    let store: TodoHubStore
    let onError: (String) -> Void

    var body: some View {
        Menu {
            ForEach(candidates) { project in
                Button {
                    run { try await store.setProject(project.id, for: session) }
                } label: {
                    if session.projectId == project.id {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
            Divider()
            Button {
                run { try await store.setProject(nil, for: session) }
            } label: {
                Text("No Project")
            }
        } label: {
            Label("Move to Project", systemImage: "folder")
        }
        .disabled(store.isOffline)
        Button {
            run { try await store.matchAutomatically(session) }
        } label: {
            Label("Match Automatically", systemImage: "wand.and.stars")
        }
        .disabled(store.isOffline || !session.projectOverride)
    }

    private var candidates: [Project] {
        store.projects
            .filter { $0.computer.id == session.computerId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        Task {
            do {
                try await body()
            } catch {
                onError(TodoHubStore.message(for: error))
            }
        }
    }
}
