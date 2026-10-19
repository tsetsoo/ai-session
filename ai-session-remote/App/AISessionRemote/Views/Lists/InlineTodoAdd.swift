import AISessionCore
import SwiftUI

/// The add row at the top of a section, or on a project page. The title is multiline and
/// stays on screen. After a successful add the title clears and focus stays in the field.
struct InlineTodoAdd: View {
    enum Place {
        case section(TodoSection)
        case project(Project)
    }

    let place: Place
    /// The phone Home-screen action focuses this row.
    var acceptsQuickAddFocus = false

    @Environment(AppModel.self) private var model
    @Environment(\.openAppSettings) private var openAppSettings
    @State private var title = ""
    @State private var projectID: String?
    @State private var makingNew = false
    @State private var newName = ""
    @State private var newFolder = ""
    @State private var localError: String?
    @FocusState private var focused: Bool
    @State private var isShown = false

    private var store: TodoHubStore { model.store }

    private var section: TodoSection {
        switch place {
        case let .section(section): section
        case let .project(project): project.section
        }
    }

    private var computerName: String? {
        switch place {
        case .section:
            store.sectionComputers[section]?.computer.name
        case let .project(project):
            store.sectionComputers[project.section]?.computer.name ?? project.computer.name
        }
    }

    private var hasComputer: Bool { computerName != nil }

    private var fields: TodoAddFields {
        switch place {
        case .project:
            TodoAddForm.fields(inProject: true, inSection: true, hasComputer: hasComputer)
        case .section:
            TodoAddForm.fields(inProject: false, inSection: true, hasComputer: hasComputer)
        }
    }

    private var sectionProjects: [Project] {
        store.projects.filter { $0.section == section }
    }

    private var newProject: TodoAddNewProject? {
        guard fields != .titleOnly, makingNew else { return nil }
        return TodoAddNewProject(name: newName, folder: newFolder)
    }

    private var canSubmit: Bool {
        guard TodoAddForm.canSubmit(title: title, newProject: newProject, hasComputer: hasComputer) else { return false }
        if fields == .titleOnly { return true }
        if makingNew { return true }
        return projectID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.xs) {
            computerLine
            if hasComputer, fields != .titleOnly {
                projectControls
            }
            if hasComputer {
                HStack(alignment: .firstTextBaseline, spacing: DS.spacing.s) {
                    TodoTitleField(title: $title, focused: $focused, onSubmit: submit)
                    Button("Add", action: submit)
                        .disabled(!canSubmit)
                }
            }
            if let localError {
                Text(localError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .disabled(store.isOffline)
        .onAppear {
            isShown = true
            pickDefaultProject()
            takeQuickActionFocus()
        }
        .onDisappear { isShown = false }
        .onChange(of: model.quickAddFocusRequested) { _, _ in takeQuickActionFocus() }
        .onChange(of: sectionProjects.map(\.id)) { _, _ in pickDefaultProject() }
    }

    @ViewBuilder
    private var computerLine: some View {
        if let computerName {
            Text(computerName)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: DS.spacing.s) {
                Text("No computer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose Computer") { openAppSettings?(.sections(section)) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var projectControls: some View {
        Picker("Project", selection: projectChoice) {
            ForEach(sectionProjects) { project in
                Text(project.name).tag(project.id)
            }
            Text("New project").tag("new")
        }
        .pickerStyle(.menu)
        if makingNew {
            TextField("Project name", text: $newName)
            TextField("Folder, e.g. ~/programming/app", text: $newFolder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
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
        guard fields != .titleOnly else { return }
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

    private func takeQuickActionFocus() {
        guard acceptsQuickAddFocus, isShown, model.quickAddFocusRequested else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard acceptsQuickAddFocus, isShown, model.quickAddFocusRequested else { return }
            model.quickAddFocusRequested = false
            focused = true
        }
    }

    private func submit() {
        guard canSubmit, !store.isOffline else { return }
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let section = section
        let makingNew = makingNew && fields != .titleOnly
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newFolder = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = projectID
        let locked = if case let .project(project) = place { project.id } else { nil as String? }
        Task {
            do {
                let projectId: String
                if let locked {
                    projectId = locked
                } else if makingNew {
                    guard let created = try await store.createProject(CreateProjectRequest(
                        name: newName, section: section, folder: newFolder
                    )) else { return }
                    projectId = created.id
                } else if let existing {
                    projectId = existing
                } else {
                    return
                }
                guard await store.createTodo(title: text, projectId: projectId) else { return }
                title = ""
                if makingNew {
                    self.makingNew = false
                    self.newName = ""
                    self.newFolder = ""
                    self.projectID = projectId
                }
                localError = nil
                focused = true
            } catch {
                localError = TodoHubStore.message(for: error)
            }
        }
    }
}

/// The title of a new todo. Multiline, so the text stays visible while typing. On iPhone the
/// mic sits on the field.
struct TodoTitleField: View {
    @Binding var title: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    @State private var note: String?
    #if os(iOS)
    @State private var dictation = Dictation()
    @State private var typedBeforeDictation = ""
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.xs) {
            HStack(alignment: .top, spacing: DS.spacing.xs) {
                TextField("Title", text: $title, axis: .vertical)
                    .lineLimit(1...8)
                    .focused(focused)
                    .onSubmit(onSubmit)
                #if os(iOS)
                dictateButton
                #endif
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: title) { _, _ in
            #if os(iOS)
            if dictation.isRunning { return }
            #endif
            note = nil
        }
        #if os(iOS)
        .onChange(of: dictation.transcript) { _, transcript in
            title = QuickAdd.text(typed: typedBeforeDictation, dictated: transcript)
        }
        .onDisappear { dictation.cancel() }
        #endif
    }

    #if os(iOS)
    private var dictateButton: some View {
        Button(action: toggleDictation) {
            Image(systemName: dictation.isRunning ? "stop.fill" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(DictateButtonStyle(isRunning: dictation.isRunning))
        .accessibilityLabel(dictation.isRunning ? "Stop Dictation" : "Dictate")
    }

    private func toggleDictation() {
        if dictation.isRunning {
            dictation.stop()
            return
        }
        note = nil
        typedBeforeDictation = title
        Task {
            do {
                try await dictation.start()
            } catch {
                note = (error as? Dictation.Failure)?.errorDescription ?? Dictation.Failure.unavailable.errorDescription
            }
        }
    }
    #endif
}

#if os(iOS)
private struct DictateButtonStyle: ButtonStyle {
    let isRunning: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(colorScheme == .dark ? Color(PlatformNativeColor(hex: 0x1C1C1E)) : .white)
            .background(DS.accent, in: Circle())
            .overlay {
                if isRunning {
                    Circle().stroke(DS.accent.opacity(0.35), lineWidth: 4).padding(-3)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
#endif
