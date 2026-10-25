import AISessionCore
import SwiftUI

/// Toolbar new-todo. The title comes first; below it, where the todo runs: the section (unless
/// the shell already picked one), the project, and the computer and folder that gives. A
/// successful add closes the sheet.
struct AddTodoSheet: View {
    var fixedSection: TodoSection?
    let store: TodoHubStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openAppSettings) private var openAppSettings
    @State private var section: TodoSection?
    @State private var draft = TodoAddDraft()
    @FocusState private var titleFocused: Bool

    /// The grouped form's own row inset. The chip row is edge to edge (so projects scroll under
    /// the card's edges) and pads itself by this to line up with the other rows.
    private static let rowInset = DS.spacing.l + 2

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

    private var hasComputer: Bool {
        guard let chosenSection else { return false }
        return store.sectionComputers[chosenSection] != nil
    }

    private var sectionProjects: [Project] {
        guard let chosenSection else { return [] }
        return store.projects.filter { $0.section == chosenSection }
    }

    /// The project the todo goes into, if it already exists.
    private var chosenProject: Project? {
        guard let id = draft.choice.projectID else { return nil }
        return sectionProjects.first { $0.id == id }
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
                    // Section chips with a fixed section and no computer would leave this empty.
                    if fixedSection == nil || hasComputer {
                        chipRow
                    }
                    if hasComputer && draft.choice.makingNew {
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
                        .disabled(!draft.canSubmit(hasComputer: hasComputer))
                }
            }
            .onAppear {
                pickDefaultProject()
                titleFocused = true
            }
            .onChange(of: chosenSection) { _, _ in
                draft.choice.clear()
                pickDefaultProject()
            }
            // A computer chosen in Settings, or projects from a refresh, while the sheet is open.
            .onChange(of: hasComputer) { _, _ in pickDefaultProject() }
            .onChange(of: sectionProjects.map(\.id)) { _, _ in pickDefaultProject() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    /// Sections and projects in one row, so no separator runs between them.
    private var chipRow: some View {
        VStack(alignment: .leading, spacing: DS.spacing.m) {
            if fixedSection == nil {
                sectionChips
                    .padding(.horizontal, Self.rowInset)
            }
            if hasComputer {
                projectChips
            }
        }
        .padding(.vertical, DS.spacing.s)
        .listRowInsets(EdgeInsets())
        .alignmentGuide(.listRowSeparatorLeading) { _ in Self.rowInset }
    }

    private var sectionChips: some View {
        HStack(spacing: DS.spacing.s) {
            ForEach(TodoSection.allCases) { option in
                Chip(isSelected: section == option, fillsWidth: true) {
                    section = option
                } content: {
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
                    Chip(isSelected: draft.choice.projectID == project.id) {
                        draft.choice.choose(project.id)
                    } content: {
                        Text(project.name)
                    }
                }
                Chip(isSelected: draft.choice.makingNew) {
                    draft.choice.chooseNew()
                } content: {
                    HStack(spacing: DS.spacing.xs) {
                        Image(systemName: "plus")
                        Text("New project")
                    }
                }
            }
            .padding(.horizontal, Self.rowInset)
            .padding(.vertical, 1)
        }
    }

    /// Where the todo's conversation will start, as `computer:folder`; or what's missing.
    @ViewBuilder
    private var destination: some View {
        if let chosenSection, let mapping = store.sectionComputers[chosenSection] {
            let folder = chosenProject?.folder ?? draft.newFolderTrimmed
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
            Text("Pick a section to choose where it runs.")
        }
    }

    private func pickDefaultProject() {
        guard hasComputer else { return }
        draft.choice.pickDefault(among: sectionProjects.map(\.id))
    }

    private func submit() {
        guard let chosenSection else { return }
        Task {
            if await draft.submit(store: store, section: chosenSection, hasComputer: hasComputer) {
                dismiss()
            }
        }
    }
}
