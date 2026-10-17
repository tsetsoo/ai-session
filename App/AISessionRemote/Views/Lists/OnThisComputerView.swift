import AISessionCore
import SwiftUI

/// "On this computer": its Claude / Codex conversations. Picking one links it to an existing
/// todo or creates a new todo from it.
struct OnThisComputerView: View {
    let computer: Computer

    @Environment(AppModel.self) private var model
    @State private var picked: RemoteConversation?
    @State private var step: Step?

    private enum Step: Hashable {
        case newTodo(RemoteConversation)
        case link(RemoteConversation)
    }

    private var store: TodoHubStore { model.store }

    var body: some View {
        ComputerConversations(
            computer: computer,
            linkedIDs: store.linkedConversationIDs,
            actionError: nil,
            isWorking: false,
            onPick: { picked = $0 }
        )
        .navigationTitle("On \(computer.name)")
        .confirmationDialog(
            picked?.title ?? "",
            isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
            titleVisibility: .visible,
            presenting: picked
        ) { remote in
            Button("New Todo from This…") { step = .newTodo(remote) }
            Button("Link to Todo…") { step = .link(remote) }
            Button("Cancel", role: .cancel) {}
        }
        .navigationDestination(item: $step) { step in
            switch step {
            case let .newTodo(remote):
                NewTodoDetailsForm(
                    computer: computer,
                    remote: remote,
                    defaultSection: defaultSection,
                    onCreate: { section, title in
                        try await store.createTodo(from: remote, on: computer, section: section, title: title)
                        self.step = nil
                    }
                )
            case let .link(remote):
                LinkToTodoList(remote: remote, computer: computer, store: store) { self.step = nil }
            }
        }
    }

    /// The section this computer serves, when exactly one does.
    private var defaultSection: TodoSection {
        let sections = TodoSection.allCases.filter { store.sectionComputers[$0]?.computer.id == computer.id }
        return sections.count == 1 ? sections[0] : .i
    }
}

/// Open todos without a conversation, by section; tapping one links the picked conversation.
private struct LinkToTodoList: View {
    let remote: RemoteConversation
    let computer: Computer
    let store: TodoHubStore
    let onLinked: () -> Void

    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }
            if !TodoSection.allCases.contains(where: { !candidates(in: $0).isEmpty }) {
                Text("Every open todo already has a conversation.")
                    .foregroundStyle(.secondary)
            }
            ForEach(TodoSection.allCases) { section in
                let todos = candidates(in: section)
                if !todos.isEmpty {
                    Section {
                        ForEach(todos) { todo in
                            Button(todo.title) { link(todo) }
                                .foregroundStyle(.primary)
                        }
                    } header: {
                        Text(section.rawValue).textCase(nil)
                    }
                }
            }
        }
        .overlay {
            if isWorking { ProgressView() }
        }
        .disabled(isWorking || store.isOffline)
        .navigationTitle("Link to Todo")
    }

    private func candidates(in section: TodoSection) -> [Todo] {
        store.todos(in: section).filter { !$0.completed && store.conversations[$0.id] == nil }
    }

    private func link(_ todo: Todo) {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await store.linkConversation(remote, on: computer, to: todo)
                onLinked()
            } catch {
                self.error = TodoHubStore.message(for: error)
            }
        }
    }
}
