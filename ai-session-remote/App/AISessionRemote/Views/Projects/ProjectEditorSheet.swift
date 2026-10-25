import AISessionCore
import SwiftUI

/// Create a project (blank, or prefilled from a suggestion) or edit one. A project belongs to
/// a section. The hub rejects a section with no computer, and a second project at the same
/// folder in that section, with a `409` that is shown as is.
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
    @Environment(\.openAppSettings) private var openAppSettings
    @State private var section: TodoSection?
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
                        LabeledContent("Section", value: project.section.rawValue)
                        LabeledContent("Computer", value: project.computer.name)
                    } else {
                        Picker("Section", selection: $section) {
                            Text("Choose").tag(TodoSection?.none)
                            ForEach(TodoSection.allCases) { item in
                                let computer = store.sectionComputers[item]?.computer.name ?? "No computer"
                                Text("\(item.rawValue) · \(computer)").tag(Optional(item))
                            }
                        }
                        if let section, store.sectionComputers[section] == nil {
                            Button("Choose Computer") { openAppSettings?(.sections(section)) }
                        }
                    }
                    FormTextField("Name", text: $name)
                    FormTextField("Folder, e.g. ~/programming/app", text: $folder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("The section's computer is where this folder lives. A nested folder is its own project.")
                }
                Section {
                    FormTextField("Repository URL (optional)", text: $repoUrl)
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
                        .foregroundStyle(DS.error)
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
        guard !isSaving, !trimmed(name).isEmpty, !trimmed(folder).isEmpty, let section else { return false }
        if isCreate { return store.sectionComputers[section] != nil }
        return true
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case let .create(suggestion):
            if let suggestion {
                name = suggestion.name
                folder = suggestion.folder
                repoUrl = suggestion.repoUrl ?? ""
                let matches = TodoSection.allCases.filter {
                    store.sectionComputers[$0]?.computer.id == suggestion.computer.id
                }
                if matches.count == 1 { section = matches[0] }
            } else {
                let ready = TodoSection.allCases.filter { store.sectionComputers[$0] != nil }
                if ready.count == 1 { section = ready[0] }
            }
        case let .edit(project):
            section = project.section
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
                    guard let section else { return }
                    let created = try await store.createProject(CreateProjectRequest(
                        name: name, section: section, folder: folder,
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
