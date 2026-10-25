import AISessionCore
import SwiftUI

/// The add row at the top of a section, or on a project page: one "Add Todo" row that opens
/// the form in place. The title is multiline and stays on screen. A successful add or Cancel
/// folds the form back into the row.
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
    @State private var draft = TodoAddDraft()
    @FocusState private var focused: Bool
    @State private var isShown = false
    @State private var isExpanded = false
    /// Set by `expand()`: the title field takes focus once it is in the list.
    @State private var focusWhenShown = false

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

    /// A project page's row adds to that project and asks only for a title.
    private var lockedProjectID: String? {
        if case let .project(project) = place { project.id } else { nil }
    }

    private var canSubmit: Bool {
        draft.canSubmit(hasComputer: hasComputer, lockedProjectID: lockedProjectID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.xs) {
            if !hasComputer {
                noComputerLine
            } else if !isExpanded {
                Button(action: expand) {
                    Label("Add Todo", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            } else {
                formHeader
                if fields != .titleOnly {
                    projectControls
                }
                HStack(alignment: .firstTextBaseline, spacing: DS.spacing.s) {
                    TodoTitleField(title: $draft.title, focused: $focused, onSubmit: submit)
                    // Borderless: in a list row a plain button would take the whole row's taps.
                    Button("Add", action: submit)
                        .buttonStyle(.borderless)
                        .disabled(!canSubmit)
                }
                .onAppear {
                    guard focusWhenShown else { return }
                    focusWhenShown = false
                    // A list row's field can't take focus in the pass that inserts it.
                    Task { @MainActor in focused = true }
                }
            }
            if let localError = draft.localError {
                Text(localError)
                    .font(.footnote)
                    .foregroundStyle(DS.error)
            }
        }
        .disabled(store.isOffline)
        .focusedValue(\.isEditingTodoText, isExpanded ? true : nil)
        .onAppear {
            isShown = true
            pickDefaultProject()
            takeQuickActionFocus()
        }
        .onDisappear { isShown = false }
        .onChange(of: model.quickAddFocusRequested) { _, _ in takeQuickActionFocus() }
        .onChange(of: sectionProjects.map(\.id)) { _, _ in pickDefaultProject() }
    }

    /// "New todo", or on a project page the computer it runs on (a section's header already
    /// names it), with Cancel.
    private var formHeader: some View {
        HStack(spacing: DS.spacing.s) {
            Group {
                if case .project = place, let computerName {
                    Text("New todo on \(computerName)")
                } else {
                    Text("New todo")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: DS.spacing.s)
            Button("Cancel", action: collapse)
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    private var noComputerLine: some View {
        HStack(spacing: DS.spacing.s) {
            Text("No computer")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose Computer") { openAppSettings?(.sections(section)) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    private func expand() {
        draft.localError = nil
        if isExpanded {
            focused = true
        } else {
            focusWhenShown = true
            withAnimation { isExpanded = true }
        }
    }

    /// Cancel, or after a successful add: the typed title goes with it.
    private func collapse() {
        focused = false
        draft.title = ""
        draft.localError = nil
        withAnimation { isExpanded = false }
    }

    @ViewBuilder
    private var projectControls: some View {
        Picker("Project", selection: $draft.pickerTag) {
            ForEach(sectionProjects) { project in
                Text(project.name).tag(project.id)
            }
            Text("New project").tag("new")
        }
        .pickerStyle(.menu)
        if draft.choice.makingNew {
            TextField("Project name", text: $draft.newName)
            TextField("Folder, e.g. ~/programming/app", text: $draft.newFolder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
        }
    }

    private func pickDefaultProject() {
        guard fields != .titleOnly else { return }
        draft.choice.pickDefault(among: sectionProjects.map(\.id))
    }

    private func takeQuickActionFocus() {
        guard acceptsQuickAddFocus, isShown, model.quickAddFocusRequested else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard acceptsQuickAddFocus, isShown, model.quickAddFocusRequested else { return }
            model.quickAddFocusRequested = false
            expand()
        }
    }

    private func submit() {
        let section = section
        Task {
            if await draft.submit(store: store, section: section, hasComputer: hasComputer,
                                  lockedProjectID: lockedProjectID) {
                collapse()
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
    var placeholder = "Title"
    /// Lines the field keeps open while empty (the New Todo sheet asks for more than a row).
    var minLines = 1

    @State private var note: String?
    #if os(iOS)
    @State private var dictation = Dictation()
    @State private var typedBeforeDictation = ""
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.xs) {
            HStack(alignment: .top, spacing: DS.spacing.xs) {
                FormTextField(placeholder, text: $title, axis: .vertical)
                    .lineLimit(minLines...max(minLines, 8))
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

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DS.onAccent)
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
