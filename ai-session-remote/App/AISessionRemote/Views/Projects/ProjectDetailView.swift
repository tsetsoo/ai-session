import AISessionCore
import SwiftData
import SwiftUI

/// A project page: header (computer, folder, repo, digest toggle), this week's stats, the
/// project's todos, its conversations and its memories.
struct ProjectDetailView: View {
    let projectId: String
    let store: TodoHubStore
    /// Opens a todo's conversation the shell's way (the phone shell pushes its frame without
    /// the tab bar; the Mac selects it in its section and starts it).
    let onOpenTodo: (Todo) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var sessions: [HubSession]?
    /// The newest extracted memories, a page at a time: a project can hold hundreds, and a
    /// List lays out every row it is given.
    @State private var memoryPage: MemoryPage?
    @State private var memoryLimit = MemoryPage.pageSize
    /// Imported Claude memory files: long and search-only, loaded when their section opens.
    @State private var showsImported = false
    @State private var imported: MemoryPage?
    @State private var importedLimit = MemoryPage.pageSize
    @State private var ideas: [Idea] = []
    @State private var pendingIdeas: [Idea] = []
    @State private var pendingMemories: [Memory] = []
    @State private var loadError: String?
    @State private var showArchived = false
    @State private var memoryActions = MemoryActions()
    @State private var editor: ProjectEditorSheet.Mode?
    @State private var confirmingDelete = false
    @State private var errorMessage: String?
    @State private var newTodoSession: HubSession?
    @State private var renameTarget: Todo?
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]

    private var project: Project? { store.project(id: projectId) }

    var body: some View {
        Group {
            if let project {
                list(project)
            } else {
                ContentUnavailableView("Project not found", systemImage: "folder.badge.questionmark",
                                       description: Text("It may have been deleted."))
            }
        }
        .navigationTitle(project?.name ?? "Project")
        .toolbar { toolbar }
        .task(id: "\(projectId)|\(store.revision)|\(showArchived)|\(memoryLimit)") { await load() }
        .task(id: "\(projectId)|\(store.revision)|\(showArchived)|\(showsImported)|\(importedLimit)") {
            if showsImported { await loadImported() }
        }
        .memoryActions(memoryActions, store: store)
        .sheet(item: $editor) { mode in
            ProjectEditorSheet(mode: mode, store: store)
        }
        .sheet(item: $newTodoSession) { session in
            if let project {
                NewTodoFromSessionSheet(session: session, project: project, store: store)
            }
        }
        .modifier(ProjectDetailAlerts(
            project: project,
            confirmingDelete: $confirmingDelete,
            errorMessage: $errorMessage,
            onDelete: deleteProject
        ))
        .todoRename($renameTarget, store: store, hosts: hosts)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    if let project { editor = .edit(project) }
                } label: {
                    Label("Edit Project…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete Project…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Project Actions")
            .disabled(project == nil || store.isOffline)
        }
    }

    private func list(_ project: Project) -> some View {
        List {
            headerSection(project)
            Section {
                WeeklyStatsCard(projectId: project.id, store: store)
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(DS.warning)
            }
            todosSection(project)
            conversationsSection(project)
            Section {
                Button {
                    model.openIdeas(projectId: project.id)
                } label: {
                    Label(ideasLinkText, systemImage: "lightbulb")
                }
            }
            if project.dailyUpdates {
                ProjectUpdatesSection(project: project, store: store, onOpenTodo: onOpenTodo)
            }
            memoriesSections(project)
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }

    // MARK: Header

    private func headerSection(_ project: Project) -> some View {
        Section {
            LabeledContent("Computer", value: project.computer.name)
            LabeledContent("Folder") {
                Text(project.folder)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            if let repo = project.repoUrl {
                LabeledContent("Repository") {
                    if let url = RepoURL.web(from: repo) {
                        Link(repo, destination: url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(repo).textSelection(.enabled)
                    }
                }
            }
            Toggle("Feed memories into new conversations", isOn: Binding(
                get: { project.digestEnabled },
                set: { setDigest($0, for: project) }
            ))
            .disabled(store.isOffline)
        }
    }

    private func setDigest(_ enabled: Bool, for project: Project) {
        Task {
            do {
                try await store.updateProject(project, UpdateProjectRequest(digestEnabled: enabled))
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
        }
    }

    // MARK: Todos

    private func todosSection(_ project: Project) -> some View {
        Section("Todos") {
            InlineTodoAdd(place: .project(project))
            let todos = store.todos(inProject: project.id)
            if todos.isEmpty {
                Text("No todos in this project").foregroundStyle(.secondary)
            }
            ForEach(todos) { todo in
                TodoRow(
                    todo: todo,
                    conversation: store.mostUrgent(forTodo: todo.id),
                    status: model.board.status(forTodo: todo.id),
                    isBusy: false,
                    canToggle: !store.isOffline,
                    scheduledLabel: store.scheduledLabel(for: todo),
                    onToggle: { Task { await store.toggle(todo) } }
                )
                .rowTap { open(todo) }
                .contextMenu {
                    RenameTodoButton(todo: todo, store: store) { renameTarget = $0 }
                    TodoProjectMenu(todo: todo, store: store)
                }
            }
        }
    }

    // MARK: Conversations

    private func conversationsSection(_ project: Project) -> some View {
        Section("Conversations") {
            if let sessions {
                if sessions.isEmpty {
                    Text("No conversations in this folder yet").foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    SessionRow(session: session, projectFolder: project.folder)
                        .contentShape(Rectangle())
                        .onTapGesture { open(session) }
                        .contextMenu { sessionMenu(session, project: project) }
                }
            } else if loadError == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func sessionMenu(_ session: HubSession, project: Project) -> some View {
        if session.todoId == nil {
            Button {
                newTodoSession = session
            } label: {
                Label("New Todo from Conversation…", systemImage: "text.bubble")
            }
            .disabled(store.isOffline)
        }
        SessionProjectMenu(session: session, store: store, onError: { errorMessage = $0 })
    }

    /// A linked conversation opens through its todo, exactly as from the Todos tab.
    private func open(_ session: HubSession) {
        guard let todoId = session.todoId else { return }
        guard let todo = store.todos.first(where: { $0.id == todoId }) else {
            errorMessage = "The todo for this conversation isn't loaded (it may be archived)."
            return
        }
        open(todo)
    }

    /// The same conversation frame as the lists; it shows preparing, problems (such as a
    /// computer this device can't reach yet) and the terminal itself.
    private func open(_ todo: Todo) {
        onOpenTodo(todo)
    }

    private var ideasLinkText: String {
        let new = ideas.filter { $0.status == .new }.count
        var text = "Ideas: \(new) new"
        if !pendingIdeas.isEmpty { text += " · \(pendingIdeas.count) waiting for OK" }
        return text
    }

    // MARK: Memories

    @ViewBuilder
    private func memoriesSections(_ project: Project) -> some View {
        Section {
            Toggle("Show archived", isOn: $showArchived)
            Button {
                memoryActions.editing = .new(projectId: project.id, todoId: nil)
            } label: {
                Label("Add Memory", systemImage: "plus")
            }
            .disabled(store.isOffline)
            if let memoryPage, memoryPage.memories.isEmpty {
                Text(showArchived ? "No memories" : "No memories yet. They appear after conversations in this folder go idle.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Memories")
        }
        PendingMemoriesSection(memories: pendingMemories, store: store)
        if let memoryPage {
            MemoryGroupSections(memories: memoryPage.memories, actions: memoryActions, store: store)
            if memoryPage.hasMore {
                Section {
                    Button("Show More Memories") { memoryLimit = MemoryPage.nextLimit(after: memoryLimit) }
                }
            }
        }
        importedSection
    }

    private var importedSection: some View {
        Section {
            Button {
                showsImported.toggle()
            } label: {
                Label(showsImported ? "Hide" : "Show", systemImage: showsImported ? "chevron.down" : "chevron.right")
            }
            if showsImported {
                if let imported {
                    if imported.memories.isEmpty {
                        Text("No imported memory files.").foregroundStyle(.secondary)
                    }
                    ForEach(imported.memories) { memory in
                        MemoryActionRow(memory: memory, actions: memoryActions, store: store,
                                        showsKind: true, lineLimit: 2)
                    }
                    if imported.hasMore {
                        Button("Show More") { importedLimit = MemoryPage.nextLimit(after: importedLimit) }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        } header: {
            Text("Imported memory files")
        } footer: {
            Text("Claude's own memory files, imported for search. Agents look them up; they aren't in the session index.")
        }
    }

    // MARK: Loading

    private func load() async {
        let limit = memoryLimit
        async let loadedSessions = store.sessions(projectId: projectId)
        async let loadedMemories = store.memories(MemoryQuery(
            projectId: projectId, includeArchived: showArchived, limit: limit + 1,
            excludeSources: [MemoryPage.importedSource]
        ))
        async let loadedPending = try? store.pendingMemories(projectId: projectId)
        async let loadedIdeas = try? store.ideas(projectId: projectId)
        async let loadedPendingIdeas = try? store.ideas(projectId: projectId, pending: true)
        do {
            let (s, m) = try await (loadedSessions, loadedMemories)
            sessions = s
            // A hub from before `exclude_source` returns imported files anyway.
            memoryPage = MemoryPage(fetched: m, limit: limit, excludingImported: true)
            pendingMemories = await loadedPending ?? []
            ideas = await loadedIdeas ?? []
            pendingIdeas = await loadedPendingIdeas ?? []
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadError = TodoHubStore.message(for: error)
        }
    }

    private func loadImported() async {
        let limit = importedLimit
        do {
            let rows = try await store.memories(MemoryQuery(
                projectId: projectId, includeArchived: showArchived, limit: limit + 1,
                sources: [MemoryPage.importedSource]
            ))
            guard !Task.isCancelled else { return }
            imported = MemoryPage(fetched: rows, limit: limit, onlyImported: true)
        } catch {
            guard !Task.isCancelled else { return }
            loadError = TodoHubStore.message(for: error)
        }
    }

    private func deleteProject() {
        guard let project else { return }
        Task {
            do {
                try await store.deleteProject(project)
                if model.selectedProjectID == projectId {
                    // The Mac's detail column: nothing to pop, so drop the selection.
                    model.selectedProjectID = nil
                } else {
                    dismiss()
                }
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
        }
    }
}

/// Delete confirmation and error alerts, kept apart to keep the page's body small.
private struct ProjectDetailAlerts: ViewModifier {
    let project: Project?
    @Binding var confirmingDelete: Bool
    @Binding var errorMessage: String?
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete \(project?.name ?? "this project")?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Project", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its todos lose the project and its conversations are matched to the remaining projects. Memories are kept.")
            }
            .alert(
                "Project",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }
}

/// A conversation on a project page: title, tool, last activity, and the todo status when linked.
private struct SessionRow: View {
    let session: HubSession
    let projectFolder: String

    var body: some View {
        HStack(alignment: .center, spacing: DS.spacing.s) {
            ToolIcon(tool: session.tool)
            details
        }
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title?.isEmpty == false ? session.title! : "Untitled")
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let status = session.status {
                    StatusBadge(ConversationDisplayStatus(status, tmuxAlive: nil))
                }
            }
            HStack(spacing: 4) {
                Text(RemoteConversationPicker.toolName(session.tool))
                if let ago = AppTheme.relativeTime(from: session.lastActivityDate) {
                    Text("· \(ago)")
                }
                if session.stats.prompts > 0 {
                    Text("· \(session.stats.prompts) prompt\(session.stats.prompts == 1 ? "" : "s")")
                }
                if session.projectOverride {
                    Image(systemName: "hand.point.up.left")
                        .accessibilityLabel("Moved by hand")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if session.cwd != projectFolder {
                Text(session.cwd)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }
}

/// "New Todo from Conversation…" for a conversation already known to the hub: straight to the
/// section and title, and the new todo joins the project.
private struct NewTodoFromSessionSheet: View {
    let session: HubSession
    let project: Project
    let store: TodoHubStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let computer {
                    NewTodoDetailsForm(
                        computer: computer,
                        remote: remote,
                        store: store,
                        lockedProject: project,
                        onCreate: { section, title, projectId in
                            try await store.createTodo(from: remote, on: computer, section: section, title: title,
                                                       projectId: projectId)
                            dismiss()
                        }
                    )
                } else {
                    ContentUnavailableView("Unknown computer", systemImage: "desktopcomputer",
                                           description: Text("This conversation's computer is no longer on the hub."))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    private var computer: Computer? {
        if project.computer.id == session.computerId { return project.computer }
        return store.computers.first { $0.id == session.computerId }
    }

    private var remote: RemoteConversation {
        RemoteConversation(
            tool: session.tool,
            sessionId: session.sessionId,
            cwd: session.cwd,
            title: session.title ?? "",
            updatedAt: session.stats.lastActivity ?? "",
            prompts: session.stats.prompts
        )
    }
}
