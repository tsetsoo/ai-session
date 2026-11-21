import AISessionCore
import SwiftUI

/// "Project ▸" submenu for a todo's context menu. A todo always has a project, so the menu
/// offers projects grouped by computer.
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
                            if todo.projectId == project.id {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Move to Project", systemImage: "folder")
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

/// Reordering here or in a list updates the shared display order.
struct ComputerOrderActions: View {
    let computerID: String
    let store: TodoHubStore

    var body: some View {
        let ids = store.computers.map(\.id)
        if let index = ids.firstIndex(of: computerID) {
            OrderActions(index: index, count: ids.count) { store.moveComputer(computerID, by: $0) }
        }
    }
}

struct ProjectOrderActions: View {
    let project: Project
    let store: TodoHubStore

    var body: some View {
        let projects = store.projectsByComputer.first { $0.computer.id == project.computer.id }?.projects ?? []
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            OrderActions(index: index, count: projects.count) { store.moveProject(project, by: $0) }
        }
    }
}

private struct OrderActions: View {
    let index: Int
    let count: Int
    let move: (Int) -> Void

    var body: some View {
        if index > 0 {
            Button("Move Up", systemImage: "arrow.up") { move(-1) }
        }
        if index + 1 < count {
            Button("Move Down", systemImage: "arrow.down") { move(1) }
        }
    }
}
