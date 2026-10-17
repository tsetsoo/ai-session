import AISessionCore
import SwiftUI

/// Create a project (blank, or prefilled from a suggestion) or edit one. The hub rejects a
/// duplicate folder and a folder inside, or containing, another project on the same computer
/// with a `409` that names the other project; that message is shown as is.
struct ProjectEditorSheet: View {
    enum Mode: Identifiable {
        case create(ProjectSuggestion?)
        case edit(Project)

        var id: String {
            switch self {
            case let .create(suggestion): "create|\(suggestion?.id ?? "")"
            case let .edit(project): "edit|\(project.id)"
            }
        }
    }

    let mode: Mode
    let store: TodoHubStore
    /// Called with the created project (not after an edit).
    var onCreated: (Project) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var computerId = ""
    @State private var name = ""
    @State private var folder = ""
    @State private var repoUrl = ""
    @State private var digestEnabled = true
    @State private var error: String?
    @State private var isSaving = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if case let .edit(project) = mode {
                        LabeledContent("Computer", value: project.computer.name)
                    } else {
                        Picker("Computer", selection: $computerId) {
                            if computerId.isEmpty { Text("Choose…").tag("") }
                            ForEach(store.computers) { Text($0.name).tag($0.id) }
                        }
                    }
                    TextField("Name", text: $name)
                    TextField("Folder, e.g. ~/programming/app", text: $folder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("Conversations in this folder or below it belong to the project. Projects on one computer can't be nested.")
                }
                Section {
                    TextField("Repository URL (optional)", text: $repoUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    Toggle("Feed memories into new conversations", isOn: $digestEnabled)
                } footer: {
                    Text("The computer writes a short digest of this project's memories where new Claude and Codex conversations in the folder load it.")
                }
                if case let .create(suggestion?) = mode, !suggestion.exampleCwds.isEmpty {
                    Section("Seen in") {
                        ForEach(suggestion.exampleCwds, id: \.self) { cwd in
                            Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isCreate ? "New Project" : "Edit Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreate ? "Create" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
        #endif
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !isSaving && !trimmed(name).isEmpty && !trimmed(folder).isEmpty && !computerId.isEmpty
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case let .create(suggestion):
            if let suggestion {
                computerId = suggestion.computer.id
                name = suggestion.name
                folder = suggestion.folder
                repoUrl = suggestion.repoUrl ?? ""
            } else if store.computers.count == 1 {
                computerId = store.computers[0].id
            }
        case let .edit(project):
            computerId = project.computer.id
            name = project.name
            folder = project.folder
            repoUrl = project.repoUrl ?? ""
            digestEnabled = project.digestEnabled
        }
    }

    private func save() {
        isSaving = true
        error = nil
        let name = trimmed(name)
        let folder = trimmed(folder)
        let repo = trimmed(repoUrl)
        Task {
            defer { isSaving = false }
            do {
                switch mode {
                case .create:
                    let created = try await store.createProject(CreateProjectRequest(
                        name: name, computerId: computerId, folder: folder,
                        repoUrl: repo.isEmpty ? nil : repo, digestEnabled: digestEnabled
                    ))
                    dismiss()
                    if let created { onCreated(created) }
                case let .edit(project):
                    let request = UpdateProjectRequest(
                        name: name == project.name ? nil : name,
                        folder: folder == project.folder ? nil : folder,
                        repoUrl: repo == (project.repoUrl ?? "") ? nil : (repo.isEmpty ? .clear : .set(repo)),
                        digestEnabled: digestEnabled == project.digestEnabled ? nil : digestEnabled
                    )
                    if request.name != nil || request.folder != nil || request.repoUrl != nil || request.digestEnabled != nil {
                        try await store.updateProject(project, request)
                    }
                    dismiss()
                }
            } catch {
                self.error = TodoHubStore.message(for: error)
            }
        }
    }
}
