import AISessionCore
import SwiftData
import SwiftUI

// Linking existing Claude / Codex conversations to todos, and creating todos from them.
// The conversation list comes from the computer over SSH (`ai-todo-sessions list --json`).

/// Searchable list of a computer's conversations, grouped by tool. Picking one that is running
/// asks for confirmation first, since opening it from the todo starts a second copy.
struct RemoteConversationPicker: View {
    let computerName: String
    /// Conversations already linked to a todo (`RemoteConversation.id`); shown but not pickable.
    let linkedIDs: Set<String>
    /// Error from the caller's last action (e.g. the hub refused the link), shown in place.
    let actionError: String?
    let isWorking: Bool
    let load: () async throws -> [RemoteConversation]
    let onPick: (RemoteConversation) -> Void

    @State private var conversations: [RemoteConversation]?
    @State private var loadError: String?
    @State private var search = ""
    @State private var runningCandidate: RemoteConversation?

    var body: some View {
        List {
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }
            if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                    Button("Try Again") { Task { await reload() } }
                }
            } else if let conversations {
                if filtered(conversations).isEmpty {
                    Text(search.isEmpty ? "No conversations on \(computerName)." : "No matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups(filtered(conversations)), id: \.tool) { group in
                    Section {
                        ForEach(group.items) { conversation in
                            row(conversation)
                        }
                    } header: {
                        Label {
                            Text(Self.toolName(group.tool))
                        } icon: {
                            ToolIcon(tool: group.tool, side: 16)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading conversations on \(computerName)…").foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $search, prompt: "Search title or folder")
        .refreshable { await reload() }
        .task { if conversations == nil { await reload() } }
        .disabled(isWorking)
        .overlay { if isWorking { ProgressView() } }
        .confirmationDialog(
            "This conversation is open right now",
            isPresented: Binding(get: { runningCandidate != nil }, set: { if !$0 { runningCandidate = nil } }),
            titleVisibility: .visible,
            presenting: runningCandidate
        ) { conversation in
            Button("Link Anyway") { onPick(conversation) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's running in a terminal on \(computerName). Opening it from the todo starts a second copy — close it there first.")
        }
    }

    private func row(_ conversation: RemoteConversation) -> some View {
        let linked = linkedIDs.contains(conversation.id)
        return Button {
            if conversation.running {
                runningCandidate = conversation
            } else {
                onPick(conversation)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
                        .lineLimit(2)
                        .foregroundStyle(linked ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if conversation.running {
                        Tag(text: "Running", color: DS.accentOnTint, fill: DS.accentTint)
                    }
                    if linked {
                        Tag(text: "Linked", color: .secondary)
                    }
                }
                HStack(spacing: 6) {
                    Label(conversation.cwd, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 8)
                    Text("\(conversation.prompts) prompt\(conversation.prompts == 1 ? "" : "s")")
                    if let ago = AppTheme.relativeTime(from: conversation.updatedDate) {
                        Text("· \(ago)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(linked)
    }

    private func reload() async {
        loadError = nil
        do {
            conversations = try await load()
        } catch {
            loadError = TodoHubStore.message(for: error)
        }
    }

    private func filtered(_ items: [RemoteConversation]) -> [RemoteConversation] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query)
        }
    }

    private func groups(_ items: [RemoteConversation]) -> [(tool: String, items: [RemoteConversation])] {
        var order: [String] = []
        var byTool: [String: [RemoteConversation]] = [:]
        for item in items {
            if byTool[item.tool] == nil { order.append(item.tool) }
            byTool[item.tool, default: []].append(item)
        }
        // Claude first, then Codex, then anything else in the order seen.
        let rank = ["claude": 0, "codex": 1]
        let seen = order
        let sorted = seen.sorted {
            (rank[$0] ?? 9, seen.firstIndex(of: $0) ?? 0) < (rank[$1] ?? 9, seen.firstIndex(of: $1) ?? 0)
        }
        return sorted.map { ($0, byTool[$0] ?? []) }
    }

    static func toolName(_ tool: String) -> String {
        RowText.toolName(tool)
    }
}

private struct Tag: View {
    let text: String
    let color: Color
    /// The capsule; a pale `color` unless given.
    var fill: Color?

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill ?? color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// A computer's conversations. Looks up its SSH host and key (a Keychain read) once when it
/// appears, not on every render.
struct ComputerConversations: View {
    let computer: Computer
    let linkedIDs: Set<String>
    let actionError: String?
    let isWorking: Bool
    let onPick: (RemoteConversation) -> Void
    @Query private var hosts: [HostEntity]
    @State private var lookup: Result<HostConnectionConfig, Error>?
    @State private var setUpPrefill: HostEditorPrefill?

    /// A failure already worded for the screen (no SSH words); the picker shows its description.
    private struct ShownError: LocalizedError {
        let errorDescription: String?
    }

    var body: some View {
        Group {
            switch lookup {
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .success(config)?:
                RemoteConversationPicker(
                    computerName: computer.name,
                    linkedIDs: linkedIDs,
                    actionError: actionError,
                    isWorking: isWorking,
                    load: {
                        do {
                            return try await RemoteConversations.list(config: config, computerName: computer.name)
                        } catch {
                            throw ShownError(errorDescription: ConversationRowActions.message(for: error, computer: computer))
                        }
                    },
                    onPick: onPick
                )
            case let .failure(error)?:
                failure(error)
            }
        }
        // Re-run when hosts change, so Set Up Access takes effect on save.
        .task(id: hosts.map(\.id)) {
            lookup = Result { try HostLookup.config(for: computer, in: hosts) }
        }
        .sheet(item: $setUpPrefill) { prefill in
            HostEditorView(prefill: prefill)
        }
    }

    @ViewBuilder
    private func failure(_ error: Error) -> some View {
        if case .noHost? = error as? HostLookup.Failure {
            ContentUnavailableView {
                Label("This device can't open conversations on \(computer.name) yet",
                      systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            } actions: {
                Button("Set Up Access") { setUpPrefill = HostEditorPrefill(computer: computer) }
                    .buttonStyle(AccentButtonStyle())
            }
        } else {
            ContentUnavailableView(
                "Conversations Unavailable",
                systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                description: Text(ConversationRowActions.message(for: error, computer: computer))
            )
        }
    }
}

/// "Link Existing Conversation…" for a todo without one: lists the conversations on the
/// computer assigned to the todo's section.
struct LinkConversationSheet: View {
    let todo: Todo
    let store: TodoHubStore
    @Environment(\.dismiss) private var dismiss
    @State private var actionError: String?
    @State private var isWorking = false
    /// Choose Computer: Settings, on this section, over this sheet.
    @State private var choosingComputer: TodoSection?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Link Conversation")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 480)
        #endif
        .sheet(item: $choosingComputer) { section in
            SettingsView(initial: .sections(section))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let computer = store.sectionComputers[todo.section]?.computer {
            ComputerConversations(
                computer: computer,
                linkedIDs: store.linkedConversationIDs,
                actionError: actionError,
                isWorking: isWorking,
                onPick: { link($0, on: computer) }
            )
        } else {
            ContentUnavailableView {
                Label("No computer runs \(todo.section.rawValue) conversations yet", systemImage: "desktopcomputer")
            } description: {
                Text("Choose which computer \(todo.section.rawValue) conversations run on, then link one from it.")
            } actions: {
                Button("Choose Computer") { choosingComputer = todo.section }
                    .buttonStyle(AccentButtonStyle())
            }
        }
    }

    private func link(_ remote: RemoteConversation, on computer: Computer) {
        isWorking = true
        actionError = nil
        Task {
            defer { isWorking = false }
            do {
                try await store.linkConversation(remote, on: computer, to: todo)
                dismiss()
            } catch {
                actionError = TodoHubStore.message(for: error)
            }
        }
    }
}

/// "New Todo from Conversation…": pick a computer, then one of its conversations, then the
/// section and title for the new todo.
struct NewTodoFromConversationSheet: View {
    let store: TodoHubStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []
    @State private var showingComputers = false

    enum Step: Hashable {
        case conversations(Computer)
        case details(Computer, RemoteConversation)
    }

    var body: some View {
        NavigationStack(path: $path) {
            computerList
                .navigationTitle("From Conversation")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .sheet(isPresented: $showingComputers) {
                    SettingsView(initial: .sections(nil))
                }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case let .conversations(computer):
                        conversations(on: computer)
                    case let .details(computer, remote):
                        NewTodoDetailsForm(
                            computer: computer,
                            remote: remote,
                            store: store,
                            onCreate: { section, title, projectId in
                                try await store.createTodo(from: remote, on: computer, section: section, title: title,
                                                           projectId: projectId)
                                dismiss()
                            }
                        )
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 480)
        #endif
    }

    private var computerList: some View {
        List {
            if store.computers.isEmpty {
                VStack(alignment: .leading, spacing: DS.spacing.s) {
                    Text("No computers yet. Add one under Settings → Sections & computers.")
                        .foregroundStyle(.secondary)
                    Button("Open Sections & Computers") { showingComputers = true }
                }
            }
            ForEach(store.computers) { computer in
                NavigationLink(value: Step.conversations(computer)) {
                    Text(computer.name)
                }
            }
        }
    }

    private func conversations(on computer: Computer) -> some View {
        ComputerConversations(
            computer: computer,
            linkedIDs: store.linkedConversationIDs,
            actionError: nil,
            isWorking: false,
            onPick: { path.append(.details(computer, $0)) }
        )
        .navigationTitle(computer.name)
    }
}

/// Section, project and title for a todo created from a conversation. The tool is already
/// known, so it is shown and not chosen. The section starts set only when this computer
/// belongs to exactly one section. A new project offers this conversation's folder.
struct NewTodoDetailsForm: View {
    let computer: Computer
    let remote: RemoteConversation
    let store: TodoHubStore
    /// Set when the todo already belongs to a project, as on a project page.
    var lockedProject: Project?
    let onCreate: (TodoSection, String, String) async throws -> Void

    @State private var section: TodoSection?
    @State private var title = ""
    @State private var projectID: String?
    @State private var makingNew = false
    @State private var newName = ""
    @State private var newFolder = ""
    @State private var error: String?
    @State private var isWorking = false
    /// Choose Computer: Settings, on the chosen section, over this form.
    @State private var choosingComputer: TodoSection?

    private var chosenSection: TodoSection? { lockedProject?.section ?? section }

    private var sectionProjects: [Project] {
        guard let chosenSection else { return [] }
        return store.projects.filter { $0.section == chosenSection }
    }

    private var hasComputer: Bool {
        guard let chosenSection else { return false }
        return store.sectionComputers[chosenSection] != nil
    }

    private var canCreate: Bool {
        guard !trimmedTitle.isEmpty, !isWorking, hasComputer else { return false }
        if lockedProject != nil { return true }
        if makingNew {
            return TodoAddForm.canSubmit(
                title: title,
                newProject: TodoAddNewProject(name: newName, folder: newFolder),
                hasComputer: true
            )
        }
        return projectID != nil
    }

    var body: some View {
        Form {
            Section {
                if lockedProject == nil {
                    Picker("Section", selection: $section) {
                        Text("Choose").tag(TodoSection?.none)
                        ForEach(TodoSection.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                }
                if let chosenSection, let mapping = store.sectionComputers[chosenSection] {
                    LabeledContent("Computer", value: mapping.computer.name)
                } else if let chosenSection {
                    // Create stays off until the section has a computer: say why and offer the fix.
                    VStack(alignment: .leading, spacing: DS.spacing.xs) {
                        Text("No computer runs \(chosenSection.rawValue) conversations yet")
                        Text("Choose one to create this todo in \(chosenSection.rawValue).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Choose Computer") { choosingComputer = chosenSection }
                }
                if let lockedProject {
                    LabeledContent("Project", value: lockedProject.name)
                } else if hasComputer {
                    Picker("Project", selection: projectChoice) {
                        ForEach(sectionProjects) { project in
                            Text(project.name).tag(project.id)
                        }
                        Text("New project").tag("new")
                    }
                    if makingNew {
                        FormTextField("Project name", text: $newName)
                        FormTextField("Folder", text: $newFolder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }
                }
                FormTextField("Title", text: $title, axis: .vertical)
            }
            Section("Conversation") {
                LabeledContent("Tool", value: RemoteConversationPicker.toolName(remote.tool))
                LabeledContent("Computer", value: computer.name)
                LabeledContent("Folder", value: remote.cwd)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }
        }
        .navigationTitle("New Todo")
        .sheet(item: $choosingComputer) { section in
            SettingsView(initial: .sections(section))
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { create() }
                    .disabled(!canCreate)
            }
        }
        .onAppear {
            if title.isEmpty {
                section = store.onlySection(for: computer)
                title = remote.title
                newFolder = remote.cwd
                if let lockedProject {
                    section = lockedProject.section
                    projectID = lockedProject.id
                } else {
                    pickDefaultProject()
                }
            }
        }
        .onChange(of: section) { _, _ in
            guard lockedProject == nil else { return }
            projectID = nil
            makingNew = false
            pickDefaultProject()
        }
        // Choose Computer just gave the section one: offer its projects.
        .onChange(of: hasComputer) { _, _ in pickDefaultProject() }
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
        guard lockedProject == nil, hasComputer else { return }
        if makingNew { return }
        if let projectID, sectionProjects.contains(where: { $0.id == projectID }) { return }
        if sectionProjects.isEmpty {
            makingNew = true
        } else {
            projectID = sectionProjects[0].id
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        guard let chosenSection else { return }
        isWorking = true
        error = nil
        let makingNew = makingNew && lockedProject == nil
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newFolder = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = lockedProject?.id ?? projectID
        Task {
            defer { isWorking = false }
            do {
                let projectId: String
                if makingNew {
                    guard let created = try await store.createProject(CreateProjectRequest(
                        name: newName, section: chosenSection, folder: newFolder
                    )) else { return }
                    projectId = created.id
                } else if let existing {
                    projectId = existing
                } else {
                    return
                }
                try await onCreate(chosenSection, trimmedTitle, projectId)
            } catch {
                self.error = TodoHubStore.message(for: error)
            }
        }
    }
}

#if DEBUG
/// Launch with `-demoConversationPicker` to see the picker with fake data (screenshots).
struct ConversationPickerDemo: View {
    var body: some View {
        NavigationStack {
            RemoteConversationPicker(
                computerName: "spreads-macbook-pro",
                linkedIDs: ["claude/c5c6d60c-0000-4000-8000-000000000002"],
                actionError: nil,
                isWorking: false,
                load: { Self.sample },
                onPick: { _ in }
            )
            .navigationTitle("Link Conversation")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    static let sample: [RemoteConversation] = {
        func ago(_ minutes: Double) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutes * 60))
        }
        return [
            RemoteConversation(tool: "claude", sessionId: "49e9880f-0000-4000-8000-000000000001", cwd: "~/Spread/Repository",
                               title: "review https://github.com/spread-ai/data-management/pull/630", updatedAt: ago(3),
                               prompts: 7, running: true, tmuxSession: "work"),
            RemoteConversation(tool: "claude", sessionId: "c5c6d60c-0000-4000-8000-000000000002", cwd: "~/Spread/Repository",
                               title: "pickup and implement EIN-10570 generator types handover", updatedAt: ago(9), prompts: 8),
            RemoteConversation(tool: "claude", sessionId: "e822d8b6-0000-4000-8000-000000000003", cwd: "~/Spread/Repository",
                               title: "help me log my hours in tempo", updatedAt: ago(190), prompts: 17),
            RemoteConversation(tool: "codex", sessionId: "019f8b4e-ff53-7201-8585-162b40a93fb3",
                               cwd: "~/programming/sigma-revenue/sigma-revenue-webapp",
                               title: "fix the competitor rates screen sorting", updatedAt: ago(60 * 24 * 3), prompts: 3),
        ]
    }()
}
#endif
