import AISessionCore
import SwiftUI

/// A project's ideas: proposals waiting for an OK, then the ideas (starred first), with
/// New Idea and "Shape an Idea with an Agent". Tapping an idea opens its details.
struct IdeasSection: View {
    let project: Project
    let store: TodoHubStore
    let ideas: [Idea]
    let pending: [Idea]
    let onOpenTodo: (String) -> Void

    @State private var adding = false
    @State private var shaping = false
    @State private var detail: Idea?
    @State private var errorMessage: String?

    var body: some View {
        if !pending.isEmpty {
            Section {
                ForEach(pending) { idea in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(idea.title, systemImage: "lightbulb")
                        if !idea.notes.isEmpty {
                            Text(idea.notes).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Approve") { run { try await store.updateIdea(idea, UpdateIdeaRequest(pending: false)) } }
                                .buttonStyle(.borderedProminent)
                            Button("Reject", role: .destructive) { run { try await store.deleteIdea(idea) } }
                                .buttonStyle(.bordered)
                        }
                        .disabled(store.isOffline)
                    }
                }
            } header: {
                Text("Ideas waiting for OK (\(pending.count))")
            }
        }
        Section {
            Button {
                adding = true
            } label: {
                Label("New Idea", systemImage: "plus")
            }
            .disabled(store.isOffline)
            Button {
                shaping = true
            } label: {
                Label("Shape an Idea with an Agent", systemImage: "bubble.left.and.text.bubble.right")
            }
            .disabled(store.isOffline)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(DS.warning)
            }
            ForEach(ideas) { idea in
                IdeaRow(idea: idea)
                    .contentShape(Rectangle())
                    .onTapGesture { detail = idea }
            }
        } header: {
            Text("Ideas")
        } footer: {
            Text("A Research job picks the starred idea first, then the oldest new one, and saves its findings here.")
        }
        .sheet(isPresented: $adding) {
            NavigationStack { NewIdeaSheet(project: project, store: store) }
        }
        .sheet(isPresented: $shaping) {
            NavigationStack { ShapeIdeaSheet(project: project, store: store) }
        }
        .sheet(item: $detail) { idea in
            NavigationStack { IdeaDetailView(idea: idea, store: store, onOpenTodo: onOpenTodo) }
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        Task {
            do {
                try await body()
                errorMessage = nil
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
        }
    }
}

private struct IdeaRow: View {
    let idea: Idea

    var body: some View {
        HStack(spacing: DS.spacing.m) {
            Image(systemName: idea.starred ? "star.fill" : "lightbulb")
                .foregroundStyle(idea.starred ? .yellow : .secondary)
                .accessibilityLabel(idea.starred ? "Starred" : "")
            VStack(alignment: .leading, spacing: 2) {
                Text(idea.title)
                    .lineLimit(2)
                    .strikethrough(idea.status == .dropped)
                    .foregroundStyle(idea.status == .dropped ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(idea.status.label)
                    if idea.findings != nil { Text("· findings") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NewIdeaSheet: View {
    let project: Project
    let store: TodoHubStore

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Idea", text: $title)
            VStack(alignment: .leading) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notes).frame(minHeight: 100)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
            }
        }
        .navigationTitle("New Idea")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    Task {
                        do {
                            try await store.createIdea(CreateIdeaRequest(projectId: project.id, title: title, notes: notes))
                            dismiss()
                        } catch {
                            errorMessage = TodoHubStore.message(for: error)
                        }
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Starts a conversation that asks questions and saves the idea; it shows up in Needs you.
private struct ShapeIdeaSheet: View {
    let project: Project
    let store: TodoHubStore

    @Environment(\.dismiss) private var dismiss
    @State private var hint = ""
    @State private var started = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if started {
                Label("Started. It will appear in Needs you within a minute or two; answer its questions there.",
                      systemImage: "checkmark.circle")
            } else {
                Section {
                    TextField("What's the idea about?", text: $hint, axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    Text("An agent asks you a few questions in a new conversation, then saves the idea to \(project.name).")
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
            }
        }
        .navigationTitle("Shape an Idea")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(started ? "Done" : "Cancel") { dismiss() } }
            if !started {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        Task {
                            do {
                                try await store.shapeIdea(projectId: project.id, hint: hint)
                                started = true
                            } catch {
                                errorMessage = TodoHubStore.message(for: error)
                            }
                        }
                    }
                    .disabled(hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// One idea: edit, star, status, findings, turn into a todo, open its research todo, delete.
struct IdeaDetailView: View {
    let idea: Idea
    let store: TodoHubStore
    let onOpenTodo: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var status = IdeaStatus.new
    @State private var starred = false
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Idea", text: $title)
                VStack(alignment: .leading) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $notes).frame(minHeight: 80)
                }
                Toggle("Starred (researched first)", isOn: $starred)
                Picker("Status", selection: $status) {
                    ForEach(IdeaStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            if let findings = idea.findings, !findings.isEmpty {
                Section("Findings") {
                    Text(findings).textSelection(.enabled)
                }
            }
            Section {
                if let todoId = idea.todoId {
                    Button("Open Todo", systemImage: "arrow.up.forward.app") {
                        dismiss()
                        onOpenTodo(todoId)
                    }
                }
                Button("Turn into Todo", systemImage: "checklist") {
                    act {
                        let todoId = try await store.ideaToTodo(idea)
                        dismiss()
                        onOpenTodo(todoId)
                    }
                }
                Button("Delete Idea", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
            .disabled(store.isOffline)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
            }
        }
        .navigationTitle("Idea")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    act {
                        try await store.updateIdea(idea, UpdateIdeaRequest(title: title, notes: notes, status: status, starred: starred))
                        dismiss()
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || store.isOffline)
            }
        }
        .confirmationDialog("Delete this idea?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                act {
                    try await store.deleteIdea(idea)
                    dismiss()
                }
            }
        }
        .onAppear {
            title = idea.title
            notes = idea.notes
            status = idea.status
            starred = idea.starred
        }
    }

    private func act(_ body: @escaping () async throws -> Void) {
        Task {
            do {
                try await body()
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
        }
    }
}
