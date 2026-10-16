import AISessionCore
import Foundation
import Observation

/// App-side state for the Todos tab: what the hub returned last, whether we're showing the
/// offline cache, and the mutations the UI performs. All work hops through `TodoHubClient`;
/// SSH happens only when a conversation is opened or closed.
@MainActor
@Observable
final class TodoHubStore {
    private(set) var todos: [Todo] = []
    /// Keyed by todo id.
    private(set) var conversations: [String: Conversation] = [:]
    private(set) var sectionComputers: [TodoSection: SectionComputer] = [:]
    private(set) var computers: [Computer] = []
    /// Ordered by name. Older hubs without projects leave this empty.
    private(set) var projects: [Project] = []
    /// Folders with conversations that could become projects.
    private(set) var suggestions: [ProjectSuggestion] = []
    /// Bumped after every successful refresh (including live updates), so screens that fetch
    /// their own data (project pages, the memories panel) know to reload.
    private(set) var revision = 0
    /// True while showing the cached snapshot because the hub could not be reached.
    private(set) var isOffline = false
    private(set) var cachedAt: Date?
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    /// Modal error for something the user just did. Background refreshes never set it.
    var errorMessage: String?
    /// Non-modal problem from a background (live-update) refresh, shown as a banner, e.g. a
    /// rejected token. Cleared by the next successful refresh.
    private(set) var backgroundIssue: String?

    enum RefreshTrigger {
        /// Pull-to-refresh, first load, settings change: failures raise `errorMessage`.
        case user
        /// Live updates and post-mutation refreshes: failures only set `backgroundIssue`.
        case background
    }

    private let cache: TodoHubCache
    private var eventsTask: Task<Void, Never>?
    /// Whether live updates should be running; they pause on a rejected token and resume
    /// after the next successful refresh.
    private var wantsLiveUpdates = false
    /// Incremented per refresh; only the most recently started refresh may apply its result,
    /// so an older, slower response can't overwrite newer state or the offline cache.
    private var refreshGeneration = 0

    init(cache: TodoHubCache = .applicationSupport()) {
        self.cache = cache
        if let snapshot = cache.load() {
            apply(todos: snapshot.todos, conversations: snapshot.conversations)
            projects = snapshot.projects
            cachedAt = snapshot.savedAt
        }
    }

    var isConfigured: Bool {
        #if DEBUG
        if demo != nil { return true }
        #endif
        return TodoHubSettings.isConfigured
    }

    #if DEBUG
    /// Canned data for screenshots (`-demoProjects`); no hub is contacted.
    private(set) var demo: TodoHubDemo?

    func loadDemo(_ demo: TodoHubDemo) {
        self.demo = demo
        apply(todos: demo.todos, conversations: demo.conversations)
        projects = demo.projects
        suggestions = demo.suggestions
        computers = demo.computers
        hasLoadedOnce = true
    }
    #endif

    func todos(in section: TodoSection) -> [Todo] {
        todos
            .filter { $0.section == section }
            .sorted { lhs, rhs in
                if lhs.completed != rhs.completed { return !lhs.completed }
                return lhs.createdAt > rhs.createdAt
            }
    }

    // MARK: Loading

    func refresh(trigger: RefreshTrigger = .user) async {
        #if DEBUG
        if demo != nil { revision += 1; return }
        #endif
        guard let client = TodoHubSettings.makeClient() else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        defer {
            if generation == refreshGeneration { isLoading = false }
            hasLoadedOnce = true
        }
        do {
            async let todos = client.listTodos()
            async let conversations = client.listConversations()
            async let mappings = client.listSectionComputers()
            async let computers = client.listComputers()
            // Optional: a hub from before projects answers 404 here, which must not break
            // the todo list. On any failure the last known projects stay.
            async let projects = try? client.listProjects()
            async let suggestions = try? client.projectSuggestions()
            let (t, c, m, comps) = try await (todos, conversations, mappings, computers)
            let (p, sugg) = await (projects, suggestions)
            // A refresh that started later has newer data; don't overwrite it.
            guard generation == refreshGeneration else { return }
            apply(todos: t, conversations: c)
            sectionComputers = Dictionary(m.map { ($0.section, $0) }, uniquingKeysWith: { _, new in new })
            self.computers = comps
            if let p { self.projects = p }
            if let sugg { self.suggestions = sugg }
            isOffline = false
            backgroundIssue = nil
            revision += 1
            let snapshot = TodoHubSnapshot(todos: t, conversations: c, projects: self.projects)
            try? cache.save(snapshot)
            cachedAt = snapshot.savedAt
            if wantsLiveUpdates && eventsTask == nil { startEventsTask() }
        } catch TodoHubError.unreachable {
            guard generation == refreshGeneration else { return }
            isOffline = true
        } catch {
            guard generation == refreshGeneration else { return }
            switch trigger {
            case .user:
                errorMessage = Self.message(for: error)
            case .background:
                backgroundIssue = Self.message(for: error)
                // Every reconnect would fail the same way: pause until a refresh succeeds
                // (pull-to-refresh or saving new settings).
                if case TodoHubError.unauthorized = error { pauseEventsTask() }
            }
        }
    }

    /// Re-fetches on every server-side change until `stopLiveUpdates()`.
    func startLiveUpdates() {
        wantsLiveUpdates = true
        startEventsTask()
    }

    func stopLiveUpdates() {
        wantsLiveUpdates = false
        pauseEventsTask()
    }

    private func startEventsTask() {
        guard eventsTask == nil, let client = TodoHubSettings.makeClient() else { return }
        eventsTask = Task { [weak self] in
            for await _ in TodoHubEvents.refreshes(baseURL: client.baseURL, token: client.token) {
                await self?.refresh(trigger: .background)
            }
        }
    }

    private func pauseEventsTask() {
        eventsTask?.cancel()
        eventsTask = nil
    }

    /// Call after the hub settings change.
    func reconnect() async {
        stopLiveUpdates()
        await refresh()
        startLiveUpdates()
    }

    // MARK: Todos

    func createTodo(section: TodoSection, title: String, projectId: String? = nil) async {
        await mutate { client in
            _ = try await client.createTodo(CreateTodoRequest(section: section, title: title, projectId: projectId))
        }
    }

    /// Assigns the todo to a project, or clears it (`nil`).
    func setProject(_ projectId: String?, for todo: Todo) async {
        guard projectId != todo.projectId else { return }
        await mutate { client in
            _ = try await client.updateTodo(
                id: todo.id,
                UpdateTodoRequest(projectId: projectId.map(ProjectChange.set) ?? .clear)
            )
        }
    }

    func toggle(_ todo: Todo) async {
        await mutate { client in _ = try await client.toggleTodo(id: todo.id) }
    }

    func delete(_ todo: Todo) async {
        await mutate { client in try await client.deleteTodo(id: todo.id) }
    }

    // MARK: Computers
    //
    // These throw instead of setting `errorMessage`: they're used from the Computers sheet,
    // which shows its own alert (TodosView's alert can't present over the sheet).

    func addComputer(name: String, hostname: String, port: Int, username: String) async throws {
        try await perform { client in
            _ = try await client.createComputer(
                CreateComputerRequest(name: name, hostname: hostname, port: port, username: username)
            )
        }
    }

    func deleteComputer(_ computer: Computer) async throws {
        try await perform { client in try await client.deleteComputer(id: computer.id) }
    }

    func assign(_ section: TodoSection, computerID: String?, cwd: String) async throws {
        try await perform { client in
            if let computerID {
                _ = try await client.setSectionComputer(section, SetSectionComputerRequest(computerId: computerID, cwd: cwd))
            } else {
                try await client.clearSectionComputer(section)
            }
        }
    }

    // MARK: Conversations

    /// Get-or-create the todo's conversation on the hub.
    func openConversation(for todo: Todo) async throws -> Conversation {
        guard let client = TodoHubSettings.makeClient() else {
            throw TodoHubError.invalidBaseURL
        }
        let conversation = try await client.openConversation(todoId: todo.id)
        conversations[todo.id] = conversation
        return conversation
    }

    /// Kills the tmux session on the computer, then marks the conversation closed on the hub.
    /// The conversation stays resumable: opening the todo again resumes it.
    func closeConversation(_ conversation: Conversation, config: HostConnectionConfig) async throws {
        let result = try await NIOSSHClient().exec(
            config,
            command: TmuxCommandBuilder.killSessionExact(tmuxName: conversation.tmuxName)
        )
        // 1 = no such session (already gone), which is fine for "close".
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw SSHRemoteError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        guard let client = TodoHubSettings.makeClient() else { throw TodoHubError.invalidBaseURL }
        conversations[conversation.todoId] = try await client.closeConversation(todoId: conversation.todoId)
        await refresh(trigger: .background)
    }

    // MARK: Linking existing conversations
    //
    // These throw: they run from sheets that show their own errors.

    /// Links a conversation found on `computer` to an existing todo.
    func linkConversation(_ remote: RemoteConversation, on computer: Computer, to todo: Todo) async throws {
        try await perform { client in
            let conversation = try await client.linkConversation(
                todoId: todo.id,
                LinkConversationRequest(computerId: computer.id, tool: remote.tool, sessionId: remote.sessionId, cwd: remote.cwd)
            )
            conversations[todo.id] = conversation
        }
    }

    /// Creates a todo already linked to a conversation found on `computer`.
    func createTodo(from remote: RemoteConversation, on computer: Computer, section: TodoSection, title: String) async throws {
        try await perform { client in
            let created = try await client.createTodoFromConversation(TodoFromConversationRequest(
                section: section, title: title, computerId: computer.id,
                tool: remote.tool, sessionId: remote.sessionId, cwd: remote.cwd
            ))
            conversations[created.todo.id] = created.conversation
        }
    }

    /// Deletes the conversation on the computer (ending its tmux session first), then unlinks
    /// it from the todo on the hub. The todo itself stays.
    func deleteConversation(_ conversation: Conversation, config: HostConnectionConfig) async throws {
        guard let client = TodoHubSettings.makeClient() else { throw TodoHubError.invalidBaseURL }
        guard !isOffline else { throw OfflineChangeError() }
        try await RemoteConversations.delete(conversation, config: config)
        try await client.deleteConversation(todoId: conversation.todoId)
        conversations[conversation.todoId] = nil
        await refresh(trigger: .background)
    }

    /// Session ids already linked to a todo, as `tool/id` (matches `RemoteConversation.id`).
    var linkedConversationIDs: Set<String> {
        Set(conversations.values.map { "\($0.tool)/\($0.sessionId)" })
    }

    // MARK: Projects
    //
    // Mutations throw: they run from sheets and pages that show their own errors (a nesting
    // 409 carries the conflicting project's name, which is shown as is).

    func project(id: String?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// Projects grouped by computer (computers by name, projects by name).
    var projectsByComputer: [(computer: Computer, projects: [Project])] {
        let byName: (Project, Project) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Dictionary(grouping: projects, by: \.computer.id).values
            .compactMap { items -> (computer: Computer, projects: [Project])? in
                guard let first = items.first else { return nil }
                return (first.computer, items.sorted(by: byName))
            }
            .sorted { $0.computer.name.localizedStandardCompare($1.computer.name) == .orderedAscending }
    }

    /// The project's todos, open first, newest first.
    func todos(inProject projectId: String) -> [Todo] {
        todos
            .filter { $0.projectId == projectId }
            .sorted { lhs, rhs in
                if lhs.completed != rhs.completed { return !lhs.completed }
                return lhs.createdAt > rhs.createdAt
            }
    }

    @discardableResult
    func createProject(_ request: CreateProjectRequest) async throws -> Project? {
        var created: Project?
        try await perform { client in created = try await client.createProject(request) }
        return created
    }

    func updateProject(_ project: Project, _ request: UpdateProjectRequest) async throws {
        try await perform { client in _ = try await client.updateProject(id: project.id, request) }
    }

    func deleteProject(_ project: Project) async throws {
        try await perform { client in try await client.deleteProject(id: project.id) }
    }

    // MARK: Sessions, stats and memories (fetched per screen, not cached)

    func sessions(projectId: String) async throws -> [HubSession] {
        #if DEBUG
        if let demo { return demo.sessions.filter { $0.projectId == projectId } }
        #endif
        return try await requireClient().listSessions(projectId: projectId)
    }

    func weekly(projectId: String?, weekStart: String?) async throws -> WeeklyStats {
        #if DEBUG
        if let demo { return demo.weekly(weekStart: weekStart) }
        #endif
        return try await requireClient().weeklyStats(weekStart: weekStart, projectId: projectId)
    }

    /// A project's memories, or a todo's when `projectId` is nil.
    func memories(projectId: String?, todoId: String? = nil, includeArchived: Bool = false) async throws -> [Memory] {
        #if DEBUG
        if let demo {
            return demo.memories.filter {
                (projectId == nil || $0.projectId == projectId)
                    && (todoId == nil || $0.todoId == todoId)
                    && (includeArchived || !$0.archived)
            }
        }
        #endif
        return try await requireClient().listMemories(MemoryQuery(
            projectId: projectId, todoId: projectId == nil ? todoId : nil,
            includeArchived: includeArchived, limit: 1000
        ))
    }

    func createMemory(_ request: CreateMemoryRequest) async throws {
        try await perform { client in _ = try await client.createMemory(request) }
    }

    func updateMemory(_ memory: Memory, _ request: UpdateMemoryRequest) async throws {
        try await perform { client in _ = try await client.updateMemory(id: memory.id, request) }
    }

    func deleteMemory(_ memory: Memory) async throws {
        try await perform { client in try await client.deleteMemory(id: memory.id) }
    }

    /// Overrides the session's project; `nil` = no project.
    func setProject(_ projectId: String?, for session: HubSession) async throws {
        try await perform { client in
            try await client.setSessionProject(tool: session.tool, sessionId: session.sessionId, projectId: projectId)
        }
    }

    /// Drops the override and lets the hub match the session by folder again.
    func matchAutomatically(_ session: HubSession) async throws {
        try await perform { client in
            try await client.setSessionProjectAuto(tool: session.tool, sessionId: session.sessionId)
        }
    }

    // MARK: Helpers

    private struct OfflineChangeError: LocalizedError {
        var errorDescription: String? { "The todo server is unreachable. Changes are disabled while offline." }
    }

    private func requireClient() throws -> TodoHubClient {
        guard let client = TodoHubSettings.makeClient() else { throw TodoHubError.invalidBaseURL }
        return client
    }

    /// Runs a hub mutation, then refreshes. Throws the mutation's error.
    private func perform(_ body: (TodoHubClient) async throws -> Void) async throws {
        #if DEBUG
        if demo != nil { return } // screenshots only: nothing to change
        #endif
        guard let client = TodoHubSettings.makeClient() else { throw TodoHubError.invalidBaseURL }
        guard !isOffline else { throw OfflineChangeError() }
        try await body(client)
        await refresh(trigger: .background)
    }

    /// `perform` for actions on the Todos screen: failures go to its alert.
    private func mutate(_ body: (TodoHubClient) async throws -> Void) async {
        do {
            try await perform(body)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func apply(todos: [Todo], conversations: [Conversation]) {
        self.todos = todos
        self.conversations = Dictionary(conversations.map { ($0.todoId, $0) }, uniquingKeysWith: { _, new in new })
    }

    static func message(for error: Error) -> String {
        if let error = error as? TodoHubError { return error.userMessage }
        if let error = error as? SSHRemoteError { return error.userMessage }
        return error.localizedDescription
    }
}
