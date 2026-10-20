import Foundation

/// What the add form asks for. A project already has a section and a computer. A section
/// already has a computer. Anywhere else asks for the section first.
public enum TodoAddFields: Equatable, Sendable {
    case titleOnly
    case projectAndTitle
    case sectionProjectAndTitle
}

/// A project created in the add form: a name and a folder. The section is the one already
/// chosen. The computer is that section's computer.
public struct TodoAddNewProject: Equatable, Sendable {
    public var name: String
    public var folder: String

    public init(name: String, folder: String) {
        self.name = name
        self.folder = folder
    }
}

public enum TodoAddForm {
    /// `hasComputer` does not change the fields. It blocks submit.
    public static func fields(inProject: Bool, inSection: Bool, hasComputer: Bool) -> TodoAddFields {
        _ = hasComputer
        if inProject { return .titleOnly }
        if inSection { return .projectAndTitle }
        return .sectionProjectAndTitle
    }

    /// False when the title is empty, a new project's name or folder is empty, or the section
    /// has no computer.
    public static func canSubmit(title: String, newProject: TodoAddNewProject?, hasComputer: Bool) -> Bool {
        guard hasComputer else { return false }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let newProject {
            let name = newProject.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let folder = newProject.folder.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || folder.isEmpty { return false }
        }
        return true
    }
}
