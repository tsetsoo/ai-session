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
        #if DEBUG
        // `-uiDemoAddSection Sp`: screenshots of the form with a section chosen.
        if DemoFixtures.isEnabled, let raw = DemoFixtures.value(after: "-uiDemoAddSection") {
            _section = State(initialValue: TodoSection(rawValue: raw))
        }
        #endif
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

    /// The project the todo goes into, if it already exists.
    private var chosenProject: Project? {
        guard !makingNew, let projectID else { return nil }
        return sectionProjects.first { $0.id == projectID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TodoTitleField(title: $title, focused: $titleFocused, onSubmit: submit,
                                   placeholder: "What needs doing?", minLines: 3)
                        .font(.title3)
                        .padding(.vertical, DS.spacing.xs)
                }
                Section {
                    // One row, so no separator runs between sections and projects.
                    VStack(alignment: .leading, spacing: DS.spacing.m) {
                        if fixedSection == nil {
                            sectionChips
                                .padding(.horizontal, DS.spacing.l + 2)
                        }
                        if hasComputer {
                            projectChips
                        }
                    }
                    .padding(.vertical, DS.spacing.s)
                    // Edge to edge, so the project row scrolls under the card's edges.
                    .listRowInsets(EdgeInsets())
                    .alignmentGuide(.listRowSeparatorLeading) { _ in DS.spacing.l + 2 }
                    if hasComputer {
                        if makingNew {
                            TextField("Project name", text: $newName)
                            TextField("Folder, e.g. ~/programming/app", text: $newFolder)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body.monospaced())
                        }
                    }
                } header: {
                    Text("Where it runs").textCase(nil)
                } footer: {
                    destination
                }
                if let localError {
                    Section {
                        Label(localError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DS.error)
                            .font(.subheadline)
                    }
                }
            }
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

    private var sectionChips: some View {
        HStack(spacing: DS.spacing.s) {
            ForEach(TodoSection.allCases) { option in
                Chip(isSelected: section == option, fillsWidth: true) {
                    section = option
                } label: {
                    Text(option.rawValue)
                }
                .accessibilityLabel("Section \(option.rawValue)")
            }
        }
    }

    /// Every project of the section and New project, one tap each.
    private var projectChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.spacing.s) {
                ForEach(sectionProjects) { project in
                    Chip(isSelected: !makingNew && projectID == project.id) {
                        projectChoice.wrappedValue = project.id
                    } label: {
                        Text(project.name)
                    }
                }
                Chip(isSelected: makingNew) {
                    projectChoice.wrappedValue = "new"
                } label: {
                    HStack(spacing: DS.spacing.xs) {
                        Image(systemName: "plus")
                        Text("New project")
                    }
                }
            }
            .padding(.horizontal, DS.spacing.l + 2)
            .padding(.vertical, 1)
        }
    }

    /// Where the todo's conversation will start, as `computer:folder`; or what's missing.
    @ViewBuilder
    private var destination: some View {
        if let chosenSection, let mapping = store.sectionComputers[chosenSection] {
            let folder = chosenProject?.folder ?? newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            Label {
                Text(folder.isEmpty ? mapping.computer.name : "\(mapping.computer.name):\(folder)")
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "desktopcomputer")
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel(folder.isEmpty ? "Runs on \(mapping.computer.name)"
                                               : "Runs on \(mapping.computer.name) in \(folder)")
        } else if let chosenSection {
            HStack(alignment: .firstTextBaseline) {
                Text("\(chosenSection.rawValue) has no computer yet.")
                Spacer()
                Button("Choose Computer") { openAppSettings?(.sections(chosenSection)) }
                    .font(.footnote.weight(.semibold))
            }
        } else {
            Text("Pick a section to see its projects.")
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

/// A capsule choice in the New Todo sheet: pale accent when chosen, grey otherwise.
private struct Chip<Label: View>: View {
    let isSelected: Bool
    var fillsWidth = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, DS.spacing.m)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 34)
                .foregroundStyle(isSelected ? DS.accentOnTint : Color.primary)
                .background(isSelected ? DS.accentTint : Color.secondary.opacity(0.12), in: Capsule())
                .overlay {
                    if isSelected { Capsule().strokeBorder(DS.accent.opacity(0.5), lineWidth: 1) }
                }
                .contentShape(Capsule())
        }
        // Borderless: in a form row a plain button would take the whole row's taps.
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
