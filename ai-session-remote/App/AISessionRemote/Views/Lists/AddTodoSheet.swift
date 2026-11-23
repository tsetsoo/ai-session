import AISessionCore
import SwiftUI

/// Adds a todo to the selected project or to a project chosen by computer.
struct AddTodoSheet: View {
    var project: Project?
    var computerID: String?
    let store: TodoHubStore

    @Environment(\.dismiss) private var dismiss
    @State private var pickedComputerID: String?
    @State private var draft = TodoAddDraft()
    @FocusState private var titleFocused: Bool

    private var chosenComputerID: String? { project?.computer.id ?? computerID ?? pickedComputerID }

    private var chosenComputer: Computer? {
        project?.computer ?? store.computers.first { $0.id == chosenComputerID }
    }

    private var computerProjects: [Project] {
        store.projectsByComputer.first { $0.computer.id == chosenComputerID }?.projects ?? []
    }

    private var chosenProject: Project? {
        project ?? computerProjects.first { $0.id == draft.choice.projectID }
    }

    private var canSubmit: Bool {
        draft.canSubmit(hasComputer: chosenComputerID != nil, lockedProjectID: project?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TodoTitleField(title: $draft.title, focused: $titleFocused, onSubmit: submit,
                                   placeholder: "What needs doing?", minLines: 3)
                        .font(.title3)
                        .padding(.vertical, DS.spacing.xs)
                }
                Section {
                    if let project {
                        LabeledContent("Project", value: project.name)
                    } else {
                        if computerID == nil {
                            Picker("Computer", selection: $pickedComputerID) {
                                Text("Choose").tag(String?.none)
                                ForEach(store.computers) { computer in
                                    Text(computer.name).tag(Optional(computer.id))
                                }
                            }
                        }
                        if chosenComputerID != nil {
                            Picker("Project", selection: $draft.pickerTag) {
                                ForEach(computerProjects) { project in
                                    Text(project.name).tag(project.id)
                                }
                                Text("New project").tag("new")
                            }
                        }
                    }
                    if project == nil && chosenComputerID != nil && draft.choice.makingNew {
                        FormTextField("Project name", text: $draft.newName)
                        FormTextField("Folder, e.g. ~/programming/app", text: $draft.newFolder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }
                } header: {
                    Text("Where it runs").textCase(nil)
                } footer: {
                    destination
                }
                if let localError = draft.localError {
                    Section {
                        Label(localError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DS.error)
                            .font(.subheadline)
                    }
                }
            }
            .skinnedList()
            .formStyle(.grouped)
            .navigationTitle("New Todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: submit)
                        .fontWeight(.semibold)
                        .disabled(!canSubmit)
                }
            }
            .onAppear {
                if store.computers.count == 1 { pickedComputerID = store.computers.first?.id }
                pickDefaultProject()
                titleFocused = true
            }
            .onChange(of: chosenComputerID) { _, _ in
                draft.choice.clear()
                pickDefaultProject()
            }
            .onChange(of: computerProjects.map(\.id)) { _, _ in pickDefaultProject() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    @ViewBuilder
    private var destination: some View {
        if let chosenComputer {
            let folder = chosenProject?.folder ?? draft.newFolderTrimmed
            Label(folder.isEmpty ? chosenComputer.name : "\(chosenComputer.name):\(folder)",
                  systemImage: "desktopcomputer")
        } else {
            Text("Choose the computer where the todo will run.")
        }
    }

    private func pickDefaultProject() {
        draft.choice.pickDefault(among: computerProjects.map(\.id))
    }

    private func submit() {
        guard let chosenComputerID else { return }
        Task {
            if await draft.submit(store: store, computerID: chosenComputerID,
                                  lockedProjectID: project?.id) {
                dismiss()
            }
        }
    }
}
