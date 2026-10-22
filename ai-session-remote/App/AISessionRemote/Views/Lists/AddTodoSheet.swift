import AISessionCore
import SwiftUI

/// Toolbar new-todo. A selected section asks for a project and a title. With no section
/// selected it asks for the section first. A successful add closes the sheet.
struct AddTodoSheet: View {
    var fixedSection: TodoSection?
    let store: TodoHubStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openAppSettings) private var openAppSettings
    @State private var section: TodoSection?
    @State private var title = ""
    @State private var projectID: String?
    @State private var makingNew = false
    @State private var newName = ""
    @State private var newFolder = ""
    @State private var localError: String?
    @FocusState private var titleFocused: Bool

    init(fixedSection: TodoSection? = nil, store: TodoHubStore) {
        self.fixedSection = fixedSection
        self.store = store
        _section = State(initialValue: fixedSection)
    }

    private var chosenSection: TodoSection? { fixedSection ?? section }

    private var fields: TodoAddFields {
        TodoAddForm.fields(
            inProject: false,
            inSection: chosenSection != nil,
            hasComputer: hasComputer
        )
    }

    private var hasComputer: Bool {
        guard let chosenSection else { return false }
        return store.sectionComputers[chosenSection] != nil
    }

    private var sectionProjects: [Project] {
        guard let chosenSection else { return [] }
        return store.projects.filter { $0.section == chosenSection }
    }

    private var newProject: TodoAddNewProject? {
        guard makingNew else { return nil }
        return TodoAddNewProject(name: newName, folder: newFolder)
    }

    private var canSubmit: Bool {
        guard fields != .sectionProjectAndTitle || chosenSection != nil else { return false }
        guard TodoAddForm.canSubmit(title: title, newProject: newProject, hasComputer: hasComputer) else { return false }
        if makingNew { return true }
        return projectID != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if fixedSection == nil {
                    Picker("Section", selection: $section) {
                        Text("Choose").tag(TodoSection?.none)
                        ForEach(TodoSection.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                }
                computerRow
                if hasComputer {
                    Picker("Project", selection: projectChoice) {
                        ForEach(sectionProjects) { project in
                            Text(project.name).tag(project.id)
                        }
                        Text("New project").tag("new")
                    }
                    if makingNew {
                        TextField("Project name", text: $newName)
                        TextField("Folder, e.g. ~/programming/app", text: $newFolder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }
                    TodoTitleField(title: $title, focused: $titleFocused, onSubmit: submit)
                }
                if let localError {
                    Label(localError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DS.error)
                        .font(.subheadline)
                }
            }
            .navigationTitle("New Todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: submit)
                        .disabled(!canSubmit)
                }
            }
            .onAppear {
                pickDefaultProject()
                titleFocused = true
            }
            .onChange(of: chosenSection) { _, _ in
                projectID = nil
                makingNew = false
                pickDefaultProject()
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    @ViewBuilder
    private var computerRow: some View {
        if let chosenSection, let mapping = store.sectionComputers[chosenSection] {
            LabeledContent("Computer", value: mapping.computer.name)
        } else if chosenSection != nil {
            HStack {
                Text("No computer").foregroundStyle(.secondary)
                Spacer()
                Button("Choose Computer") {
                    if let chosenSection { openAppSettings?(.sections(chosenSection)) }
                }
            }
        }
    }

    private var projectChoice: Binding<String> {
        Binding(
            get: { makingNew ? "new" : (projectID ?? "new") },
            set: { value in
                if value == "new" {
                    makingNew = true
                    projectID = nil
                } else {
                    makingNew = false
                    projectID = value
                }
            }
        )
    }

    private func pickDefaultProject() {
        guard hasComputer else { return }
        if makingNew { return }
        if let projectID, sectionProjects.contains(where: { $0.id == projectID }) { return }
        if let first = sectionProjects.first {
            self.projectID = first.id
            makingNew = false
        } else {
            projectID = nil
            makingNew = true
        }
    }

    private func submit() {
        guard canSubmit, let chosenSection, !store.isOffline else { return }
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let makingNew = makingNew
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newFolder = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = projectID
        Task {
            do {
                let projectId: String
                if makingNew {
                    guard let created = try await store.createProject(CreateProjectRequest(
                        name: newName, section: chosenSection, folder: newFolder
                    )) else { return }
                    projectId = created.id
                    // Kept even if the todo fails, so trying again doesn't make a second project.
                    self.makingNew = false
                    self.newName = ""
                    self.newFolder = ""
                    self.projectID = projectId
                } else if let existing {
                    projectId = existing
                } else {
                    return
                }
                try await store.addTodo(title: text, projectId: projectId)
                dismiss()
            } catch {
                localError = TodoHubStore.message(for: error)
            }
        }
    }
}
