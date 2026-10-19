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
    /// Bumped when projects or suggestions change, or when the set of conversation identities
    /// changes (todo id + session id). Status and status-message heartbeats do not bump it:
    /// project pages, weekly stats, and memories refetch off this, while lists observe `todos`
    /// and `conversations` directly.
    private(set) var revision = 0
    /// True while showing the cached snapshot because the hub could not be reached.
    private(set) var isOffline = false
    private(set) var cachedAt: Date?
    /// What a successful refresh fetched, for `onRefresh`.
    struct Fetched {
        let todos: [Todo]
        let conversations: [Conversation]
        /// The first fetch since launch or since reconnecting (hub settings changed, or the
        /// live-update socket dropped): a fresh baseline for "turned waiting" alerts.
        let isBaseline: Bool
    }

    /// Called after every successful refresh. `AppModel` diffs it for "needs you" alerts.
    @ObservationIgnored var onRefresh: ((Fetched) -> Void)?
    /// The next fetch starts a fresh baseline (see `Fetched.isBaseline`).
    @ObservationIgnored private var baselinePending = true
    /// Bumped by `startNewBaseline`. A fetch only clears the flag when this is still the epoch
    /// it started in, so a reconnect during an in-flight fetch leaves the baseline for the follow-up.
    @ObservationIgnored private var baselineEpoch = 0
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    /// Modal error for something the user just did. Background refreshes never set it.
    var errorMessage: String?
    /// Non-modal problem from a background (live-update) refresh, shown as a banner, e.g. a
    /// rejected token. Cleared by the next successful refresh.
    private(set) var backgroundIssue: String?
    /// The background issue is a rejected token, fixed in Settings → Todo server.
    private(set) var tokenRejected = false

    enum RefreshTrigger {
        /// Pull-to-refresh, first load, settings change: failures raise `errorMessage`.
        /// Runs immediately.
        case user
        /// Live updates and post-mutation refreshes: failures only set `backgroundIssue`.
        /// Coalesced onto one fetch per burst (see `TodoHubRefreshCoalescer`).
        case background
    }

    private let cache: TodoHubCache
    /// Where hub calls get their client (`TodoHubSettings.makeClient` outside tests); see `hubClient()`.
    private let makeClient: () -> TodoHubClient?
    /// Background refreshes (websocket and post-mutation) share this one coalescer.
    /// Internal so tests can see how many requests have joined a burst.
    let coalescer: TodoHubRefreshCoalescer
    /// Todos, conversations, and projects last successfully written. A matching snapshot skips
    /// the encode and the disk write. Nil until the cache is loaded or the first save lands.
    private var savedTodos: [Todo]?
    private var savedConversations: [Conversation]?
    private var savedProjects: [Project]?
    /// Successful cache writes. Unchanged snapshots do not increment it.
    private(set) var cacheSaveCount = 0
    private var eventsTask: Task<Void, Never>?
    /// Whether live updates should be running; they pause on a rejected token and resume
    /// after the next successful refresh.
    private var wantsLiveUpdates = false
    /// Incremented per refresh; only the most recently started refresh may apply its result,
    /// so an older, slower response can't overwrite newer state or the offline cache.
    private var refreshGeneration = 0

    init(cache: TodoHubCache = TodoHubStore.defaultCache(),
         makeClient: @escaping () -> TodoHubClient? = TodoHubSettings.makeClient,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.cache = cache
        self.makeClient = makeClient
        let coalescer = TodoHubRefreshCoalescer(sleep: sleep)
        self.coalescer = coalescer
        coalescer.onRefresh = { [weak self] immediate in
            await self?.performRefresh(trigger: immediate ? .user : .background)
        }
        if let snapshot = cache.load() {
            apply(todos: snapshot.todos, conversations: snapshot.conversations)
            projects = snapshot.projects
            cachedAt = snapshot.savedAt
            rememberSaved(snapshot)
        }
    }

    /// The offline cache in Application Support, except in a `-uiDemo` launch: a demo never
    /// reads (or shows) the real hub's data.
    nonisolated static func defaultCache() -> TodoHubCache {
        #if DEBUG
        if DemoFixtures.isEnabled { return scratchCache() }
        #endif
        return .applicationSupport()
    }

    #if DEBUG
    /// A cache file of its own that doesn't exist yet: starts empty and is never the real one.
    nonisolated static func scratchCache() -> TodoHubCache {
        TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-todo-hub-cache-\(UUID().uuidString).json"))
    }
    #endif

    var isConfigured: Bool {
        #if DEBUG
        if demo != nil { return true }
        #endif
        return TodoHubSettings.isConfigured
    }

    #if DEBUG
    /// Canned data for screenshots (`-demoProjects`, `-uiDemo`); no hub is contacted.
    private(set) var demo: TodoHubDemo?

    /// The offline cache file this store reads and writes.
    var cacheFileURL: URL { cache.fileURL }

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
        guard hubClient() != nil else { return }
        // User refreshes (first load, settings) run now. Background ones share the coalescer
        // with the websocket loop, so a mutation and its echo become one fetch.
        await coalescer.submit(immediate: trigger == .user)
    }

    /// The fetch behind `refresh`. One runs at a time; the coalescer starts the follow-up.
    private func performRefresh(trigger: RefreshTrigger) async {
        guard let client = hubClient() else { return }
        let startedAtEpoch = baselineEpoch
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
            await acceptFetch(
                todos: t, conversations: c, sectionComputers: m, computers: comps,
                projects: p, suggestions: sugg, startedAtEpoch: startedAtEpoch,
                trigger: trigger
            )
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
                tokenRejected = false
                // Every reconnect would fail the same way: pause until a refresh succeeds
                // (pull-to-refresh or saving new settings).
                if case TodoHubError.unauthorized = error {
                    tokenRejected = true
                    pauseEventsTask()
                }
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
        guard eventsTask == nil, let client = hubClient() else { return }
        eventsTask = Task { [weak self] in
            for await event in TodoHubEvents.refreshes(baseURL: client.baseURL, token: client.token) {
                if event == .reconnected { self?.startNewBaseline() }
                // Don't await. The loop has to keep reading so the next event joins this
                // burst; awaiting here would fetch once per event.
                Task { [weak self] in
                    await self?.refresh(trigger: .background)
                }
            }
        }
    }

    private func pauseEventsTask() {
        eventsTask?.cancel()
        eventsTask = nil
    }

    /// Shows what a refresh fetched and tells `onRefresh`.
    func applyFetched(todos: [Todo], conversations: [Conversation]) {
        deliver(todos: todos, conversations: conversations, startedAtEpoch: baselineEpoch)
    }

    /// `startedAtEpoch` is the baseline epoch when this fetch began. A reconnect in between
    /// leaves `baselinePending` set so the follow-up, not this snapshot, is the fresh baseline.
    private func deliver(todos: [Todo], conversations: [Conversation], startedAtEpoch: Int) {
        apply(todos: todos, conversations: conversations)
        let superseded = baselineEpoch != startedAtEpoch
        let isBaseline = superseded || baselinePending
        if !superseded { baselinePending = false }
        onRefresh?(Fetched(todos: todos, conversations: conversations, isBaseline: isBaseline))
    }

    /// The next fetch is a fresh baseline: nothing that turned waiting meanwhile alerts.
    func startNewBaseline() {
        baselinePending = true
        baselineEpoch += 1
    }

    /// Call after the hub settings change.
    func reconnect() async {
        startNewBaseline()
        stopLiveUpdates()
        await refresh()
        startLiveUpdates()
    }

    #if DEBUG
    /// Fills the store without touching the hub or the cache (demo launches and tests), and
    /// makes it a demo store: refreshes and changes then never reach a hub.
    func seedForDemo(todos: [Todo], conversations: [Conversation],
                     sectionComputers: [SectionComputer], computers: [Computer]) {
        demo = TodoHubDemo(computers: computers, projects: [], suggestions: [], todos: todos,
                           conversations: conversations, sessions: [], memories: [])
        apply(todos: todos, conversations: conversations)
        self.sectionComputers = Dictionary(sectionComputers.map { ($0.section, $0) }, uniquingKeysWith: { _, new in new })
        self.computers = computers
        hasLoadedOnce = true
        // As if just fetched: the sync line reads "Synced · just now", not the real cache's age.
        cachedAt = .now
    }
    #endif

    // MARK: Todos

    @discardableResult
    func createTodo(title: String, projectId: String) async -> Bool {
        do {
            try await perform { client in
                _ = try await client.createTodo(CreateTodoRequest(title: title, projectId: projectId))
            }
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
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
    // which shows its own alert (the shell's alert can't present over the sheet).

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

    func assign(_ section: TodoSection, computerID: String?) async throws {
        try await perform { client in
            if let computerID {
                _ = try await client.setSectionComputer(section, SetSectionComputerRequest(computerId: computerID))
            } else {
                try await client.clearSectionComputer(section)
            }
        }
    }

    // MARK: Conversations

    /// Get-or-create the todo's conversation on the hub. An existing conversation is resumed
    /// with the tool it already has.
    func openConversation(for todo: Todo) async throws -> Conversation {
        try await openConversation(for: todo, tool: "claude", config: nil)
    }

    /// Opens for `tool`. Codex and Cursor have no id yet: the computer starts one, and the id
    /// it prints is stored before the terminal attaches. A start that never produces an id
    /// removes the hub conversation so the tool step shows again.
    func openConversation(for todo: Todo, tool: String, config: HostConnectionConfig?) async throws -> Conversation {
        guard let client = hubClient() else {
            throw TodoHubError.invalidBaseURL
        }
        var conversation = try await client.openConversation(todoId: todo.id, tool: tool)
        if conversation.sessionId.isEmpty {
            // An empty id is a start that has not finished. Keep it out of the store, and drop
            // the hub row unless this call is about to fill the id in.
            guard ConversationStart.startsFresh(tool), let config else {
                try? await client.deleteConversation(todoId: todo.id)
                conversations[todo.id] = nil
                throw TodoHubError.conflict("No \(tool) conversation appeared")
            }
            do {
                let result = try await NIOSSHClient().exec(
                    config,
                    command: TmuxCommandBuilder.freshTodoConversation(
                        tmuxName: conversation.tmuxName, cwd: conversation.cwd, tool: tool
                    )
                )
                let created = ConversationStart.createdSessionId(from: result.stdout)
                guard result.exitCode != 94, let created else {
                    throw TodoHubError.conflict("No new \(tool) conversation appeared")
                }
                conversation = try await client.setConversationSession(todoId: todo.id, sessionId: created)
            } catch {
                try? await client.deleteConversation(todoId: todo.id)
                conversations[todo.id] = nil
                throw error
            }
        }
        conversations[todo.id] = conversation
        return conversation
    }

    /// Kills the tmux session on the computer, then marks the conversation closed on the hub.
    /// The conversation stays resumable: opening the todo again resumes it.
    func closeConversation(_ conversation: Conversation, config: HostConnectionConfig) async throws {
        #if DEBUG
        if demo != nil { return } // demo data: nothing runs on a computer
        #endif
        let result = try await NIOSSHClient().exec(
            config,
            command: TmuxCommandBuilder.killSessionExact(tmuxName: conversation.tmuxName)
        )
        // 1 = no such session (already gone), which is fine for "close".
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw SSHRemoteError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        guard let client = hubClient() else { throw TodoHubError.invalidBaseURL }
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

    /// Creates a todo already linked to a conversation found on `computer`, in `projectId`.
    func createTodo(
        from remote: RemoteConversation,
        on computer: Computer,
        section: TodoSection,
        title: String,
        projectId: String
    ) async throws {
        try await perform { client in
            let created = try await client.createTodoFromConversation(TodoFromConversationRequest(
                section: section, title: title, projectId: projectId, computerId: computer.id,
                tool: remote.tool, sessionId: remote.sessionId, cwd: remote.cwd
            ))
            conversations[created.todo.id] = created.conversation
            if created.todo.projectId != projectId {
                _ = try await client.updateTodo(id: created.todo.id, UpdateTodoRequest(projectId: .set(projectId)))
            }
        }
    }

    /// The section this computer serves, when exactly one does.
    func onlySection(for computer: Computer) -> TodoSection? {
        let sections = TodoSection.allCases.filter { sectionComputers[$0]?.computer.id == computer.id }
        return sections.count == 1 ? sections[0] : nil
    }

    /// Deletes the conversation on the computer (ending its tmux session first), then unlinks
    /// it from the todo on the hub. The todo itself stays.
    func deleteConversation(_ conversation: Conversation, config: HostConnectionConfig) async throws {
        #if DEBUG
        if demo != nil { return } // demo data: nothing runs on a computer
        #endif
        guard let client = hubClient() else { throw TodoHubError.invalidBaseURL }
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

    /// Every hub call's client. None for a demo store: demo data never reaches a hub.
    private func hubClient() -> TodoHubClient? {
        #if DEBUG
        if demo != nil { return nil }
        #endif
        return makeClient()
    }

    private func requireClient() throws -> TodoHubClient {
        guard let client = hubClient() else { throw TodoHubError.invalidBaseURL }
        return client
    }

    /// Runs a hub mutation, then refreshes. Throws the mutation's error.
    private func perform(_ body: (TodoHubClient) async throws -> Void) async throws {
        #if DEBUG
        if demo != nil { return } // screenshots only: nothing to change
        #endif
        guard let client = hubClient() else { throw TodoHubError.invalidBaseURL }
        guard !isOffline else { throw OfflineChangeError() }
        try await body(client)
        await refresh(trigger: .background)
    }

    /// `perform` for todo changes: failures go to the shell's Todos alert.
    private func mutate(_ body: (TodoHubClient) async throws -> Void) async {
        do {
            try await perform(body)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Applies one successful fetch: assigns a collection only when it changed, bumps `revision`
    /// only for project, suggestion, or conversation-identity changes. A user refresh bumps it
    /// too, so pull-to-refresh reloads project conversations, memories, and weekly stats.
    /// Skips the cache write when todos, conversations, and projects match the last successful save.
    private func acceptFetch(
        todos: [Todo],
        conversations: [Conversation],
        sectionComputers: [SectionComputer],
        computers: [Computer],
        projects: [Project]?,
        suggestions: [ProjectSuggestion]?,
        startedAtEpoch: Int,
        trigger: RefreshTrigger
    ) async {
        let previousIdentities = Self.conversationIdentities(self.conversations)
        deliver(todos: todos, conversations: conversations, startedAtEpoch: startedAtEpoch)
        let identitiesChanged = Self.conversationIdentities(self.conversations) != previousIdentities

        let mappedSections = Dictionary(
            sectionComputers.map { ($0.section, $0) }, uniquingKeysWith: { _, new in new }
        )
        if self.sectionComputers != mappedSections { self.sectionComputers = mappedSections }
        if self.computers != computers { self.computers = computers }

        var projectsChanged = false
        if let projects, projects != self.projects {
            self.projects = projects
            projectsChanged = true
        }
        var suggestionsChanged = false
        if let suggestions, suggestions != self.suggestions {
            self.suggestions = suggestions
            suggestionsChanged = true
        }
        if identitiesChanged || projectsChanged || suggestionsChanged || trigger == .user {
            revision += 1
        }
        isOffline = false
        backgroundIssue = nil
        tokenRejected = false
        await saveCacheIfChanged(todos: todos, conversations: conversations, projects: self.projects)
    }

    /// Todo id + session id. Status and status message are not part of the identity, so a
    /// heartbeat does not look like a new conversation.
    private static func conversationIdentities(_ conversations: [String: Conversation]) -> Set<ConversationIdentity> {
        Set(conversations.values.map { ConversationIdentity(todoId: $0.todoId, sessionId: $0.sessionId) })
    }

    private struct ConversationIdentity: Hashable {
        var todoId: String
        var sessionId: String
    }

    private func rememberSaved(_ snapshot: TodoHubSnapshot) {
        savedTodos = snapshot.todos
        savedConversations = snapshot.conversations
        savedProjects = snapshot.projects
    }

    /// Encodes and writes off the main actor. `TodoHubCache.save` is the existing file format.
    private func saveCacheIfChanged(todos: [Todo], conversations: [Conversation], projects: [Project]) async {
        if savedTodos == todos, savedConversations == conversations, savedProjects == projects {
            cachedAt = .now
            return
        }
        let snapshot = TodoHubSnapshot(todos: todos, conversations: conversations, projects: projects)
        let cache = self.cache
        let wrote = await Task.detached { () -> Bool in
            do {
                try cache.save(snapshot)
                return true
            } catch {
                return false
            }
        }.value
        if wrote {
            rememberSaved(snapshot)
            cacheSaveCount += 1
        }
        cachedAt = snapshot.savedAt
    }

    private func apply(todos: [Todo], conversations: [Conversation]) {
        if self.todos != todos { self.todos = todos }
        let mapped = Dictionary(conversations.map { ($0.todoId, $0) }, uniquingKeysWith: { _, new in new })
        if self.conversations != mapped { self.conversations = mapped }
    }

    static func message(for error: Error) -> String {
        if let error = error as? TodoHubError { return error.userMessage }
        if let error = error as? SSHRemoteError { return error.userMessage }
        return error.localizedDescription
    }
}

/// Collapses a burst of refresh requests onto one fetch.
///
/// A background request waits `window` from the first request in the burst, then runs once.
/// Later requests in that wait join it; they do not push the deadline out. A user request
/// does not wait: it cancels a pending window and runs now. If a fetch is already in flight,
/// every request that arrives during it is remembered and exactly one more fetch runs when
/// the in-flight one finishes (immediate if any of those requests was a user refresh).
///
/// `sleep` is `Task.sleep` in the app. Tests pass a clock they can advance.
@MainActor
final class TodoHubRefreshCoalescer {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Not main-actor isolated: the initializer's default argument is evaluated off the actor.
    nonisolated static let window: Duration = .milliseconds(400)

    /// `immediate` is true when the run should use user-refresh error handling.
    var onRefresh: ((Bool) async -> Void)?

    private let delay: Duration
    private let sleep: Sleep
    /// How many fetches have finished.
    private var finished = 0
    /// Generation of the fetch currently running, if any.
    private var inflight: Int?
    /// `nil` when nothing arrived during the in-flight fetch. `false` is a background follow-up.
    private var followUpImmediate: Bool?
    /// Generation the pending window will satisfy.
    private var waitingGeneration: Int?
    /// Bumped to invalidate a delay that already left `sleep` or that a later window replaced.
    private var delayID = 0
    private var delayTask: Task<Void, Never>?
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    /// Requests that have been scheduled. Tests wait until a burst has actually joined.
    private(set) var submitted = 0

    init(delay: Duration = TodoHubRefreshCoalescer.window, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.delay = delay
        self.sleep = sleep
    }

    /// Returns when the fetch that covers this request has finished.
    func submit(immediate: Bool) async {
        let needed = schedule(immediate: immediate)
        await waitUntil(finishedAtLeast: needed)
    }

    private func schedule(immediate: Bool) -> Int {
        let needed: Int
        if let inflight {
            followUpImmediate = (followUpImmediate ?? false) || immediate
            needed = inflight + 1
        } else if !immediate, let waitingGeneration {
            needed = waitingGeneration
        } else if immediate {
            cancelDelay()
            needed = begin(immediate: true)
        } else {
            let generation = finished + 1
            startDelay(generation: generation)
            needed = generation
        }
        submitted += 1
        return needed
    }

    private func startDelay(generation: Int) {
        delayID += 1
        let id = delayID
        waitingGeneration = generation
        let delay = self.delay
        let sleep = self.sleep
        delayTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.delayElapsed(id: id)
        }
    }

    private func cancelDelay() {
        delayID += 1
        delayTask?.cancel()
        delayTask = nil
        waitingGeneration = nil
    }

    private func delayElapsed(id: Int) {
        guard id == delayID, inflight == nil, waitingGeneration != nil else { return }
        waitingGeneration = nil
        delayTask = nil
        begin(immediate: false)
    }

    @discardableResult
    private func begin(immediate: Bool) -> Int {
        let generation = finished + 1
        inflight = generation
        let onRefresh = self.onRefresh
        Task { [weak self] in
            await onRefresh?(immediate)
            self?.ended(generation)
        }
        return generation
    }

    private func ended(_ generation: Int) {
        guard inflight == generation else { return }
        inflight = nil
        finished = generation
        let ready = waiters.keys.filter { $0 <= finished }
        for key in ready {
            let pending = waiters.removeValue(forKey: key) ?? []
            for waiter in pending { waiter.resume() }
        }
        if let follow = followUpImmediate {
            followUpImmediate = nil
            begin(immediate: follow)
        }
    }

    private func waitUntil(finishedAtLeast needed: Int) async {
        if finished >= needed { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if finished >= needed {
                cont.resume()
                return
            }
            waiters[needed, default: []].append(cont)
        }
    }
}
