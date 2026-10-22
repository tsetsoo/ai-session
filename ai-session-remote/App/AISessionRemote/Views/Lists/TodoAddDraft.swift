import AISessionCore
import Observation

/// What a todo add form has typed and chosen, and its submit. The New Todo sheet and the inline
/// add rows share it, so a fix to adding lands in both.
@MainActor
@Observable
final class TodoAddDraft {
    var title = ""
    var choice = TodoAddProjectChoice()
    var newName = ""
    var newFolder = ""
    var localError: String?
    /// An add is under way: another Add or Return does nothing until it ends, so a double tap
    /// can't make two todos or two projects.
    private(set) var isSubmitting = false

    /// The name and folder typed for New project, when it is chosen.
    var newProject: TodoAddNewProject? {
        choice.makingNew ? TodoAddNewProject(name: newName, folder: newFolder) : nil
    }

    /// The folder New project will use, trimmed; empty unless New project is chosen.
    var newFolderTrimmed: String {
        choice.makingNew ? newFolder.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// A project id, or "new" for New project: the tag of a project `Picker`.
    var pickerTag: String {
        get { choice.makingNew ? "new" : (choice.projectID ?? "new") }
        set {
            if newValue == "new" {
                choice.chooseNew()
            } else {
                choice.choose(newValue)
            }
        }
    }

    /// `lockedProjectID`: a project page's add row, which only asks for a title.
    func canSubmit(hasComputer: Bool, lockedProjectID: String? = nil) -> Bool {
        guard !isSubmitting else { return false }
        let newProject = lockedProjectID == nil ? newProject : nil
        guard TodoAddForm.canSubmit(title: title, newProject: newProject, hasComputer: hasComputer) else { return false }
        return lockedProjectID != nil || choice.isChosen
    }

    /// Creates New project first when it is chosen, then the todo. True once the todo is added;
    /// otherwise `localError` says why. Offline, the store's offline error is the message.
    func submit(store: TodoHubStore, section: TodoSection, hasComputer: Bool,
                lockedProjectID: String? = nil) async -> Bool {
        guard canSubmit(hasComputer: hasComputer, lockedProjectID: lockedProjectID) else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        localError = nil
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let projectId: String
            if let lockedProjectID {
                projectId = lockedProjectID
            } else if choice.makingNew {
                guard let created = try await store.createProject(CreateProjectRequest(
                    name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
                    section: section,
                    folder: newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                )) else { return false }
                projectId = created.id
                // Kept even if the todo fails, so trying again doesn't make a second project.
                choice.choose(projectId)
                newName = ""
                newFolder = ""
            } else if let existing = choice.projectID {
                projectId = existing
            } else {
                return false
            }
            try await store.addTodo(title: text, projectId: projectId)
            return true
        } catch {
            localError = TodoHubStore.message(for: error)
            return false
        }
    }
}
