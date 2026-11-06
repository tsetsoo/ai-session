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
    /// Keyed by conversation id. A conversation decoded without an id (an older hub) is keyed
    /// `todo:<todo id>` so a one-conversation cache does not collapse onto `""`.
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
    /// Memories agents proposed (`ai-todo-memory add`) that wait for an OK, on every project
    /// and computer. Shown as a badge on Projects.
    private(set) var pendingMemoryCount = 0
    /// Scheduler jobs. Empty on a hub from before the scheduler.
    private(set) var jobs: [SchedulerJob] = []
    /// Ideas of every project for Automation → Ideas (pending ones included), loaded on demand.
    private(set) var allIdeas: [Idea] = []
    /// Ideas agents proposed that wait for an OK, on every project. Badge on Automation → Ideas;
    /// one hub call per refresh keeps it current even before the Ideas list is opened.
    private(set) var pendingIdeaCount = 0
    /// Watcher issues still open (or resolving). Loaded with every refresh: badge on
    /// Automation → Watchers.
    private(set) var openWatchIssues: [WatchIssue] = []
    /// Each conversation's review at a glance (open items, reviewing), by conversation id.
    /// Empty from a hub before reviews.
    private(set) var reviewSummaries: [String: ReviewSummary] = [:]
    /// Watcher issues cleared in the last 7 days, loaded on demand.
    private(set) var recentWatchIssues: [WatchIssue] = []
    var openWatchIssueCount: Int { openWatchIssues.count }
    /// Watchers installed per computer (from their runners), loaded on demand.
    private(set) var watchersByComputer: [String: [WatcherInfo]] = [:]
    /// The newest runs across jobs for Automation → Activity; nil on a hub without `/api/runs`.
    private(set) var recentRuns: [RecentRun]? = []
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

    /// MCP server lists by computer id, for this app session only.
    private var mcpLists: [String: [MCPServer]] = [:]
    /// Computers whose host scripts have no `ai-todo-mcp` (listing exited 127).
    private var mcpListMissing: Set<String> = []
    /// Computers whose `ai-todo-open` rejected `--mcp` (scripts from before MCP support).
    private var mcpFlagUnsupported: Set<String> = []
    /// Computers whose `ai-todo-transcript` rejected `--activity`; their chat shows messages only
    /// until the flag is tried again (the helpers may have been updated meanwhile).
    private var transcriptActivityUnsupported = RetryAfter()

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
    /// Bumped whenever a change's own response is applied locally. A fetch that started before
    /// it would put the old state back, so it is dropped; the change already queued a newer one.
    private var localChanges = 0

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
        let changesAtStart = localChanges
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
            // Optional too: a hub from before pending memories ignores the filter.
            async let pending = try? client.listMemories(MemoryQuery(limit: 1000, pending: true))
            async let loadedJobs = try? client.listJobs()
            async let pendingIdeasList = try? client.listIdeas(projectId: nil, pending: true)
            async let watchIssues = try? client.listWatchIssues(state: "open")
            async let reviews = try? client.reviewSummaries()
            let (t, c, m, comps) = try await (todos, conversations, mappings, computers)
            let (p, sugg, pend, jobList, pendIdeas) = await (projects, suggestions, pending, loadedJobs, pendingIdeasList)
            let openIssues = await watchIssues
            let reviewList = await reviews
            // A refresh that started later has newer data; don't overwrite it.
            guard generation == refreshGeneration else { return }
            guard changesAtStart == localChanges else { return }
            await acceptFetch(
                todos: t, conversations: c, sectionComputers: m, computers: comps,
                projects: p, suggestions: sugg, startedAtEpoch: startedAtEpoch,
                trigger: trigger
            )
            if let pend { pendingMemoryCount = pend.filter(\.pending).count }
            if let jobList { jobs = jobList }
            if let pendIdeas { pendingIdeaCount = pendIdeas.filter(\.pending).count }
            if let openIssues { openWatchIssues = openIssues }
            if let reviewList {
                let byID = Dictionary(reviewList.map { ($0.conversationId, $0) }, uniquingKeysWith: { $1 })
                if byID != reviewSummaries { reviewSummaries = byID }
            }
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
        // Another hub's memories must not show while the panel refetches.
        memoryPanelCache.removeAll()
        startNewBaseline()
        stopLiveUpdates()
        await refresh()
        startLiveUpdates()
    }

    #if DEBUG
    /// Fills the store without touching the hub or the cache (demo launches and tests), and
    /// makes it a demo store: refreshes and changes then never reach a hub.
    func seedForDemo(todos: [Todo], conversations: [Conversation],
                     sectionComputers: [SectionComputer], computers: [Computer], projects: [Project] = []) {
        demo = TodoHubDemo(computers: computers, projects: projects, suggestions: [], todos: todos,
                           conversations: conversations, sessions: [], memories: [])
        apply(todos: todos, conversations: conversations)
        self.sectionComputers = Dictionary(sectionComputers.map { ($0.section, $0) }, uniquingKeysWith: { _, new in new })
        self.computers = computers
        self.projects = projects
        hasLoadedOnce = true
        // As if just fetched: the sync line reads "Synced · just now", not the real cache's age.
        cachedAt = .now
    }
    #endif

    // MARK: Todos

    /// `createTodo` for forms that show the failure themselves: the New Todo sheet (the shell's
    /// alert can't present over it) and the inline add rows.
    func addTodo(title: String, projectId: String) async throws {
        try await perform { client in
            upsert(try await client.createTodo(CreateTodoRequest(title: title, projectId: projectId)))
        }
    }

    @discardableResult
    func createTodo(title: String, projectId: String) async -> Bool {
        do {
            try await addTodo(title: title, projectId: projectId)
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
            upsert(try await client.updateTodo(
                id: todo.id,
                UpdateTodoRequest(projectId: projectId.map(ProjectChange.set) ?? .clear)
            ))
        }
    }

    func toggle(_ todo: Todo) async {
        await mutate { client in upsert(try await client.toggleTodo(id: todo.id)) }
    }

    func setOnHold(_ onHold: Bool, for todo: Todo) async {
        await mutate { client in
            let updated = try await client.updateTodo(id: todo.id, UpdateTodoRequest(onHold: onHold))
            guard updated.onHold == onHold else {
                throw NSError(domain: "TodoHub", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "The todo hub needs to be updated to support On hold."
                ])
            }
            upsert(updated)
        }
    }

    /// Renames the todo on the hub. Throws: the rename dialog shows its own errors.
    func rename(_ todo: Todo, to title: String) async throws {
        try await perform { client in
            upsert(try await client.updateTodo(id: todo.id, UpdateTodoRequest(title: title)))
        }
    }

    /// Gives one of the todo's conversations the same name on its computer.
    func renameConversation(_ conversation: Conversation, to title: String, config: HostConnectionConfig) async throws {
        #if DEBUG
        if demo != nil { return } // demo data: nothing runs on a computer
        #endif
        try await RemoteConversations.rename(conversation, to: title, config: config)
    }

    func delete(_ todo: Todo) async {
        await mutate { client in
            try await client.deleteTodo(id: todo.id)
            removeTodo(id: todo.id)
        }
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

    /// Sets (or, with nil, clears) the MCP servers new conversations on this computer start with.
    func setDefaultServers(_ names: [String]?, for computer: Computer) async throws {
        let change: MCPDefaultChange = names.map { .set($0) } ?? .clear
        try await perform { client in
            let updated = try await client.updateComputer(id: computer.id, UpdateComputerRequest(mcpDefault: change))
            upsert(updated)
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

    func conversations(forTodo id: String) -> [Conversation] {
        conversations.values.filter { $0.todoId == id }
    }

    func mostUrgent(forTodo id: String) -> Conversation? {
        ConversationIndex.mostUrgent(conversations(forTodo: id))
    }

    /// The conversation id to land in when opening this todo from a project, a section, or an alert.
    func conversationToOpen(forTodo id: String) -> String? {
        mostUrgent(forTodo: id)?.listKey
    }

    /// The conversation on screen: the selected row when it belongs to this todo, otherwise the most urgent.
    func displayed(forTodo id: String, selectedKey: String?) -> Conversation? {
        if let selectedKey, let match = conversations.values.first(where: { $0.listKey == selectedKey }), match.todoId == id {
            return match
        }
        return mostUrgent(forTodo: id)
    }

    /// Get-or-create the todo's conversation on the hub. An existing conversation is resumed
    /// with the tool it already has.
    func openConversation(for todo: Todo) async throws -> Conversation {
        try await openConversation(for: todo, tool: "claude", config: nil)
    }

    /// Opens for `tool`. Codex and Cursor have no id yet: the computer starts one, and the id
    /// it prints is stored before the terminal attaches. A start that never produces an id
    /// kills the tmux session it may have left and removes the hub conversation, so the tool
    /// step shows again and the next start is a new one.
    /// `mcpServers` is the selection the conversation starts with; an existing conversation keeps its own.
    func openConversation(
        for todo: Todo, tool: String, config: HostConnectionConfig?, mcpServers: [String]? = nil
    ) async throws -> Conversation {
        guard let client = hubClient() else {
            throw TodoHubError.invalidBaseURL
        }
        var conversation = try await client.openConversation(todoId: todo.id, tool: tool, mcpServers: mcpServers)
        if conversation.sessionId.isEmpty {
            // An empty id is a start that has not finished. Keep it out of the store, and drop
            // the hub row unless this call is about to fill the id in.
            guard ConversationStart.startsFresh(tool), let config else {
                try? await forgetOnHub(client, conversation)
                forget(conversation)
                throw TodoHubError.conflict("No \(tool) conversation appeared")
            }
            do {
                let servers = conversation.mcpServers
                var result = try await NIOSSHClient().exec(
                    config,
                    command: TmuxCommandBuilder.freshTodoConversation(
                        tmuxName: conversation.tmuxName, cwd: conversation.cwd, tool: tool, mcpServers: servers,
                        worktree: conversation.worktree
                    )
                )
                if Self.shouldRetryWithoutServers(result, servers: servers, tool: tool) {
                    result = try await NIOSSHClient().exec(
                        config,
                        command: TmuxCommandBuilder.freshTodoConversation(
                            tmuxName: conversation.tmuxName, cwd: conversation.cwd, tool: tool,
                            worktree: conversation.worktree
                        )
                    )
                }
                let created = ConversationStart.createdSessionId(from: result.stdout)
                guard result.exitCode != 94, let created else {
                    let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw TodoHubError.conflict(
                        detail.isEmpty ? "No new \(tool) conversation appeared" : detail
                    )
                }
                conversation = try await storeSession(client, conversation, created)
            } catch {
                // The script may already have created the tmux session. Leaving it makes the
                // next fresh open attach to a session that never printed an id.
                _ = try? await NIOSSHClient().exec(
                    config,
                    command: TmuxCommandBuilder.killSessionExact(tmuxName: conversation.tmuxName)
                )
                try? await forgetOnHub(client, conversation)
                forget(conversation)
                throw error
            }
        }
        remember(conversation)
        return conversation
    }

    /// A second conversation on the same computer and folder. The caller has already decided
    /// to create it: a cancelled summary never reaches here.
    func duplicateConversation(
        source: Conversation, tool: String, label: String,
        ownWorktree: Bool = false, model: String? = nil, baseSha: String? = nil
    ) async throws -> Conversation {
        guard let client = hubClient() else { throw TodoHubError.invalidBaseURL }
        let created = try await client.duplicateConversation(
            todoId: source.todoId, sourceId: source.id, tool: tool, label: label,
            ownWorktree: ownWorktree, model: model, baseSha: baseSha
        )
        remember(created)
        return created
    }

    /// Gives the new row the session id the tool is actually using, then the terminal can attach.
    /// A fork's minted id is replaced with the transcript the fork created. A Codex or Cursor row
    /// has none until the fresh start prints one. A failure removes the row and the tmux session.
    ///
    /// A hand-off text (transcript or summary) for Claude or Codex is the new tool's first
    /// message: written to a file on the computer and started with `--prompt-file`, so it never
    /// depends on typing into a tool that may not be ready yet.
    func prepareDuplicate(
        _ created: Conversation, plan: DuplicateHandoff.Plan, config: HostConnectionConfig
    ) async throws -> Conversation {
        let firstPrompt = DuplicateHandoff.firstPrompt(plan, tool: created.tool)
        switch DuplicateIn.followUp(plan: plan, created: created) {
        case .resume:
            guard let firstPrompt else { return created }
            do {
                let path = try await writeHandoff(firstPrompt, on: created, config: config)
                let result = try await NIOSSHClient().exec(config, command: TmuxCommandBuilder.openTodoConversation(
                    tmuxName: created.tmuxName, cwd: created.cwd, sessionId: created.sessionId, tool: created.tool,
                    mcpServers: created.mcpServers, worktree: created.worktree, promptFile: path, detached: true,
                    model: created.model, worktreeBase: created.worktreeBase
                ))
                try RemoteConversations.check(result, computerName: created.computer.name)
                return created
            } catch {
                await discardStart(created, config: config)
                throw error
            }
        case .captureFresh:
            var path: String?
            if let firstPrompt {
                do {
                    path = try await writeHandoff(firstPrompt, on: created, config: config)
                } catch {
                    await discardStart(created, config: config)
                    throw error
                }
            }
            return try await captureNewSession(
                created, config: config,
                command: TmuxCommandBuilder.freshTodoConversation(
                    tmuxName: created.tmuxName, cwd: created.cwd, tool: created.tool,
                    mcpServers: created.mcpServers, worktree: created.worktree, promptFile: path,
                    model: created.model, worktreeBase: created.worktreeBase
                ),
                fallbackCommand: Self.shouldOfferFallback(created)
                    ? TmuxCommandBuilder.freshTodoConversation(
                        tmuxName: created.tmuxName, cwd: created.cwd, tool: created.tool,
                        worktree: created.worktree, promptFile: path,
                        model: created.model, worktreeBase: created.worktreeBase
                    ) : nil
            )
        case let .captureFork(sourceSessionId):
            let arguments = ForkCommand.arguments(tool: created.tool, sessionId: sourceSessionId) ?? []
            return try await captureNewSession(
                created, config: config,
                command: Self.forkCommand(created, arguments: arguments)
            )
        }
    }

    /// Scripts installed before MCP support reject `--mcp` with exit 64. The start is then run
    /// once more without it, as the conversation would have started before this feature.
    static func shouldRetryWithoutServers(_ result: SSHExecResult, servers: [String]?, tool: String) -> Bool {
        result.exitCode == 64 && servers != nil && tool != "cursor"
    }

    private static func shouldOfferFallback(_ conversation: Conversation) -> Bool {
        conversation.mcpServers != nil && conversation.tool != "cursor"
    }

    /// The hub copies the source's MCP selection onto the new row, so the fork starts with the
    /// same servers as the conversation it was forked from.
    static func forkCommand(_ created: Conversation, arguments: [String]) -> String {
        TmuxCommandBuilder.forkDetached(
            tmuxName: created.tmuxName, cwd: created.cwd, arguments: arguments, mcpServers: created.mcpServers,
            worktree: created.worktree
        )
    }

    /// A commit with the conversation's current state, uncommitted and untracked files included
    /// (`ai-todo-review status`), kept from git's clean-up (`keep`): an added agent starts there.
    func snapshot(of conversation: Conversation, config: HostConnectionConfig) async throws -> String {
        let output = try await remoteStdout(
            TmuxCommandBuilder.reviewStatus(cwd: conversation.cwd), config: config, computerName: conversation.computer.name
        )
        let status = try JSONDecoder().decode(ReviewStatus.self, from: Data(output.utf8))
        _ = try await remoteStdout(
            TmuxCommandBuilder.reviewKeep(cwd: conversation.cwd, revision: status.revision),
            config: config, computerName: conversation.computer.name
        )
        return status.revision
    }

    /// The hand-off text in a private file on the conversation's computer; its path.
    private func writeHandoff(_ text: String, on conversation: Conversation, config: HostConnectionConfig) async throws -> String {
        try await remoteStdout(
            TmuxCommandBuilder.writePromptFile(text: text), config: config, computerName: conversation.computer.name
        )
    }

    /// A start that failed: its tmux session (if any) and its hub row go.
    private func discardStart(_ conversation: Conversation, config: HostConnectionConfig) async {
        _ = try? await NIOSSHClient().exec(
            config, command: TmuxCommandBuilder.killSessionExact(tmuxName: conversation.tmuxName)
        )
        if let client = hubClient() { try? await forgetOnHub(client, conversation) }
        forget(conversation)
    }

    private func captureNewSession(
        _ conversation: Conversation, config: HostConnectionConfig, command: String,
        fallbackCommand: String? = nil
    ) async throws -> Conversation {
        guard let client = hubClient() else { throw TodoHubError.invalidBaseURL }
        do {
            var result = try await NIOSSHClient().exec(config, command: command)
            if let fallbackCommand,
               Self.shouldRetryWithoutServers(result, servers: conversation.mcpServers, tool: conversation.tool) {
                result = try await NIOSSHClient().exec(config, command: fallbackCommand)
            }
            let createdId = ConversationStart.createdSessionId(from: result.stdout)
            guard result.exitCode != 94, let createdId else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw TodoHubError.conflict(
                    detail.isEmpty ? "No new \(conversation.tool) conversation appeared" : detail
                )
            }
            let stored = try await storeSession(client, conversation, createdId)
            remember(stored)
            return stored
        } catch {
            _ = try? await NIOSSHClient().exec(
                config, command: TmuxCommandBuilder.killSessionExact(tmuxName: conversation.tmuxName)
            )
            try? await forgetOnHub(client, conversation)
            forget(conversation)
            throw error
        }
    }

    /// The source conversation's user and assistant text, from the computer that has it.
    func captureTranscript(of conversation: Conversation, config: HostConnectionConfig) async throws -> String {
        try await remoteStdout(
            TmuxCommandBuilder.conversationTranscript(tool: conversation.tool, sessionId: conversation.sessionId),
            config: config, computerName: conversation.computer.name
        )
    }

    /// The conversation's transcript. With `previous` (what the chat already shows) only later
    /// entries are fetched and appended, so polling a long conversation stays cheap.
    func conversationMessages(of conversation: Conversation, config: HostConnectionConfig, previous: [ConversationMessage] = []) async throws -> [ConversationMessage] {
        #if DEBUG
        if DemoFixtures.isEnabled { return DemoFixtures.chatTranscript }
        #endif
        let computer = conversation.computer
        if !transcriptActivityUnsupported.isBlocked(computer.id) {
            do {
                let after = conversation.tool == "cursor" ? nil : ConversationMessage.lastLine(of: previous)
                let output = try await remoteStdout(
                    TmuxCommandBuilder.conversationTranscript(
                        tool: conversation.tool, sessionId: conversation.sessionId, json: true, activity: true, after: after
                    ),
                    config: config, computerName: computer.name
                )
                let fetched = try ConversationMessage.decodeList(Data(output.utf8))
                return after == nil ? fetched : previous + fetched
            } catch is RemoteConversations.OldHelper {
                transcriptActivityUnsupported.block(computer.id)
            }
        }
        let output = try await remoteStdout(
            TmuxCommandBuilder.conversationTranscript(tool: conversation.tool, sessionId: conversation.sessionId, json: true),
            config: config, computerName: computer.name
        )
        return try ConversationMessage.decodeList(Data(output.utf8))
    }

    /// A one-shot summary. The model is a new `claude -p`, not the conversation being duplicated.
    func summarizeConversation(_ conversation: Conversation, config: HostConnectionConfig) async throws -> String {
        try await remoteStdout(
            TmuxCommandBuilder.summarizeConversation(tool: conversation.tool, sessionId: conversation.sessionId),
            config: config, computerName: conversation.computer.name
        )
    }

    // MARK: MCP servers

    /// The server files on the computer, listed once per app session. A computer without the
    /// helper (127) gives `[]` and is remembered as having no list; any other failure throws and
    /// is not remembered, so the next call tries again.
    func mcpServers(on computer: Computer, config: HostConnectionConfig) async throws -> [MCPServer] {
        #if DEBUG
        if demo != nil { return [] } // screenshots only: nothing runs on a computer
        #endif
        if let cached = mcpLists[computer.id] { return cached }
        if mcpListMissing.contains(computer.id) { return [] }
        if let list = try await RemoteConversations.listMCPServers(config: config, computerName: computer.name) {
            mcpLists[computer.id] = list
            return list
        }
        mcpListMissing.insert(computer.id)
        return []
    }

    /// Whether the computer can list MCP servers: nil until a listing has finished.
    func hasMCPList(_ computer: Computer) -> Bool? {
        if mcpLists[computer.id] != nil { return true }
        return mcpListMissing.contains(computer.id) ? false : nil
    }

    /// The servers an attach passes to `ai-todo-open`: the conversation's own, else what a new
    /// one would start with (applied only if the tool actually starts). Cursor has none, and
    /// neither does a computer whose scripts don't know `--mcp`.
    func launchServers(for conversation: Conversation) -> [String]? {
        guard conversation.tool != "cursor", !mcpFlagUnsupported.contains(conversation.computer.id) else { return nil }
        if let servers = conversation.mcpServers { return servers }
        let todo = todos.first { $0.id == conversation.todoId }
        let computer = computers.first { $0.id == conversation.computer.id } ?? conversation.computer
        return MCPSelection.initial(project: project(id: todo?.projectId), computer: computer)
    }

    /// Later attaches to this computer leave `--mcp` out, for this app session.
    func noteServersUnsupported(on computer: Computer) {
        mcpFlagUnsupported.insert(computer.id)
    }

    /// Records the servers a running or resumable conversation uses. nil = not managed.
    func setServers(_ names: [String]?, for conversation: Conversation) async throws {
        try await perform { client in
            remember(try await client.setConversationServers(id: conversation.id, names))
        }
    }

    /// Switches resuming after a session (5-hour) limit on or off for one conversation. Off
    /// cancels a planned resume.
    func setResumeOnReset(_ on: Bool, for conversation: Conversation) async throws {
        try await perform { client in
            let updated = try await client.setConversationResume(id: conversation.id, on: on)
            localChanges += 1
            remember(updated)
        }
    }

    /// The one-tap Resume of a paused conversation: its computer checks it, takes the hub's
    /// lease and types the resume message. Reopening a closed session can take a minute.
    func resumeAfterLimit(_ conversation: Conversation, config: HostConnectionConfig) async throws -> LimitResumeOutcome {
        #if DEBUG
        if demo != nil { return LimitResumeOutcome(resumed: true) }
        #endif
        let result = try await NIOSSHClient(execTimeoutSeconds: 300).exec(
            config,
            command: TmuxCommandBuilder.resumeAfterLimit(tool: conversation.tool, sessionId: conversation.sessionId)
        )
        guard let outcome = LimitResumeOutcome.parse(stdout: result.stdout, exitCode: result.exitCode) else {
            // 64: helpers from before resuming; 127: none at all.
            if result.exitCode == 64 || result.exitCode == TmuxCommandBuilder.scriptMissingExitCode {
                throw RemoteConversations.ScriptMissing(computer: conversation.computer.name)
            }
            throw SSHRemoteError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        refreshSoon()
        return outcome
    }

    /// Sets (or, with nil, clears) the MCP servers new conversations in the project start with.
    func setDefaultServers(_ names: [String]?, for project: Project) async throws {
        let change: MCPDefaultChange = names.map { .set($0) } ?? .clear
        try await updateProject(project, UpdateProjectRequest(mcpDefault: change))
    }

    /// A missing helper, program or transcript is reported as that, not as a retryable failure.
    private func remoteStdout(_ command: String, config: HostConnectionConfig, computerName: String) async throws -> String {
        let result = try await NIOSSHClient().exec(config, command: command)
        try RemoteConversations.check(result, computerName: computerName)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func storeSession(_ client: TodoHubClient, _ conversation: Conversation, _ sessionId: String) async throws -> Conversation {
        if conversation.id.isEmpty {
            return try await client.setConversationSession(todoId: conversation.todoId, sessionId: sessionId)
        }
        return try await client.setConversationSession(id: conversation.id, sessionId: sessionId)
    }

    private func forgetOnHub(_ client: TodoHubClient, _ conversation: Conversation) async throws {
        if conversation.id.isEmpty {
            try await client.deleteConversation(todoId: conversation.todoId)
        } else {
            try await client.deleteConversation(id: conversation.id)
        }
    }

    private func remember(_ conversation: Conversation) {
        conversations[Self.storageKey(conversation)] = conversation
    }

    /// Opening an idle result acknowledges only that result. A response racing with a
    /// new busy/idle turn must not overwrite the newer status already received by the app.
    @discardableResult
    func review(_ conversation: Conversation) async -> Bool {
        #if DEBUG
        if DemoFixtures.isEnabled { return true }
        #endif
        // A paused conversation isn't a result yet: looking at it must not stop its resume.
        guard conversation.status == .idle, conversation.paused == nil, !conversation.reviewed,
              !conversation.id.isEmpty, !isOffline, let client = hubClient() else { return conversation.reviewed }
        do {
            let updated = try await client.reviewConversation(id: conversation.id, statusRevision: conversation.statusRevision)
            let key = Self.storageKey(conversation)
            if let current = conversations[key], current.statusRevision == updated.statusRevision,
               current.status == updated.status {
                localChanges += 1
                remember(updated)
            }
            refreshSoon()
            return updated.reviewed && updated.status == .idle && updated.statusRevision == conversation.statusRevision
        } catch {
            // An older/offline hub leaves the result unacknowledged; it must never vanish
            // from review only on this device while the write hasn't succeeded.
            return false
        }
    }

    private func forget(_ conversation: Conversation) {
        conversations[Self.storageKey(conversation)] = nil
    }

    private static func storageKey(_ conversation: Conversation) -> String {
        conversation.id.isEmpty ? "todo:\(conversation.todoId)" : conversation.id
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
        let closed = try await conversation.id.isEmpty
            ? client.closeConversation(todoId: conversation.todoId)
            : client.closeConversation(id: conversation.id)
        remember(closed)
        refreshSoon()
    }

    /// Ends only the tmux session; the hub row keeps its status, so hooks keep reporting and
    /// the attach that follows (a restart with new servers) resumes the same conversation.
    func endSession(
        _ conversation: Conversation, config: HostConnectionConfig,
        exec: (HostConnectionConfig, String) async throws -> SSHExecResult = { try await NIOSSHClient().exec($0, command: $1) }
    ) async throws {
        #if DEBUG
        if demo != nil { return } // demo data: nothing runs on a computer
        #endif
        let result = try await exec(config, TmuxCommandBuilder.killSessionExact(tmuxName: conversation.tmuxName))
        // 1 = no such session (already gone), which is fine, as for Close.
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw SSHRemoteError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Whether a Codex conversation has a rollout on the computer. Codex 0.163+ writes none
    /// until the first message, and `ai-todo-open` can't resume one without it.
    func codexHasRollout(
        _ conversation: Conversation, config: HostConnectionConfig,
        exec: (HostConnectionConfig, String) async throws -> SSHExecResult = { try await NIOSSHClient().exec($0, command: $1) }
    ) async throws -> Bool {
        #if DEBUG
        if demo != nil { return true } // demo data: nothing runs on a computer
        #endif
        let result = try await exec(config, TmuxCommandBuilder.codexHasRollout(sessionId: conversation.sessionId))
        switch result.exitCode {
        case 0: return true
        case 1: return false
        default: throw SSHRemoteError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
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
            remember(conversation)
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
            remember(created.conversation)
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
        try await forgetOnHub(client, conversation)
        forget(conversation)
        refreshSoon()
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
        try await perform { client in
            let project = try await client.createProject(request)
            upsert(project)
            created = project
        }
        return created
    }

    func updateProject(_ project: Project, _ request: UpdateProjectRequest) async throws {
        try await perform { client in upsert(try await client.updateProject(id: project.id, request)) }
    }

    func deleteProject(_ project: Project) async throws {
        try await perform { client in
            try await client.deleteProject(id: project.id)
            if projects.contains(where: { $0.id == project.id }) {
                localChanges += 1
                projects.removeAll { $0.id == project.id }
            }
        }
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

    /// What a todo's conversations and their sub-agents used. The demo has no readings.
    func todoUsage(todoId: String) async throws -> UsageSummary {
        #if DEBUG
        if demo != nil { return UsageSummary() }
        #endif
        return try await requireClient().todoUsage(todoId: todoId).usage
    }

    /// What used the most of a week; `nil` in the demo.
    func heaviest(weekStart: String?, limit: Int = 5) async throws -> HeavyUsage? {
        #if DEBUG
        if demo != nil { return nil }
        #endif
        return try await requireClient().heaviest(weekStart: weekStart, limit: limit)
    }

    /// A job's usage over all runs and its newest runs one by one.
    func jobUsage(jobId: String, runs: Int = 20) async throws -> JobUsage? {
        #if DEBUG
        if demo != nil { return nil }
        #endif
        return try await requireClient().jobUsage(jobId: jobId, runs: runs)
    }

    /// Any memory query: the panel next to a conversation asks for pages and sources.
    func memories(_ query: MemoryQuery) async throws -> [Memory] {
        #if DEBUG
        if let demo {
            let rows = demo.memories.filter {
                (query.projectId == nil || $0.projectId == query.projectId)
                    && (query.todoId == nil || $0.todoId == query.todoId)
                    && (query.sessionId == nil || $0.sessionId == query.sessionId)
                    && (query.excludeSessionId == nil || $0.sessionId != query.excludeSessionId)
                    && (query.includeArchived || !$0.archived)
                    && (query.sources.isEmpty || query.sources.contains($0.source))
                    && !query.excludeSources.contains($0.source)
            }
            return Array(MemoryGrouping.sorted(rows).prefix(query.limit ?? rows.count))
        }
        #endif
        return try await requireClient().listMemories(query)
    }

    /// The memories panel's last result for each conversation, so switching back to one
    /// shows it at once while it refetches. Not observed: only the panel reads it.
    @ObservationIgnored private var memoryPanelCache: [String: MemoryPanelSnapshot] = [:]

    func cachedMemoryPanel(_ key: String) -> MemoryPanelSnapshot? { memoryPanelCache[key] }

    func cacheMemoryPanel(_ snapshot: MemoryPanelSnapshot, for key: String) {
        memoryPanelCache[key] = snapshot
    }

    /// Memories waiting for approval: a project's, or a computer's global ones.
    func pendingMemories(projectId: String? = nil, computerId: String? = nil) async throws -> [Memory] {
        #if DEBUG
        if demo != nil { return [] }
        #endif
        let memories = try await requireClient().listMemories(MemoryQuery(
            projectId: projectId, limit: 1000, pending: true,
            computerId: computerId, global: computerId == nil ? nil : true
        ))
        // A hub from before pending memories ignores the filter: show nothing rather than everything.
        return memories.filter(\.pending)
    }

    /// The computer's last doctor report as the hub keeps it (the Health page shows it while
    /// it asks the computer itself, and instead when it can't).
    func computerHealth(computerId: String) async throws -> ComputerHealthSnapshot {
        try await requireClient().computerHealth(id: computerId)
    }

    // MARK: Scheduler

    /// "Scheduled · <job>" for a scheduled todo, nil for any other.
    func scheduledLabel(for todo: Todo) -> String? {
        guard let id = todo.scheduledJobId else { return nil }
        return ScheduledMarker.text(jobName: jobs.first { $0.id == id }?.name)
    }

    func createJob(_ request: CreateJobRequest) async throws {
        try await perform { client in _ = try await client.createJob(request) }
    }

    /// Creates the job and returns its id once `jobs` has it.
    func createJobReturningID(_ request: CreateJobRequest) async throws -> String {
        var id = ""
        try await perform { client in id = try await client.createJob(request).id }
        await refresh()
        return id
    }

    /// Reloads `allIdeas` (approved and pending, every project).
    func loadAllIdeas() async {
        #if DEBUG
        if demo != nil { return }
        #endif
        guard let client = try? requireClient() else { return }
        async let approved = try? client.listIdeas(projectId: nil)
        async let pending = try? client.listIdeas(projectId: nil, pending: true)
        let (a, p) = await (approved, pending)
        if let a { allIdeas = a + (p ?? []).filter(\.pending) }
        if let p { pendingIdeaCount = p.filter(\.pending).count }
    }

    func researchIdea(_ idea: Idea) async throws {
        try await perform { client in _ = try await client.researchIdea(id: idea.id) }
        await loadAllIdeas()
        await loadRecentRuns()
    }

    /// Reloads open and recently cleared watcher issues.
    func loadWatchIssues() async {
        #if DEBUG
        if demo != nil { return }
        #endif
        guard let client = try? requireClient() else { return }
        async let open = try? client.listWatchIssues(state: "open")
        async let recent = try? client.listWatchIssues(state: "recent")
        let (o, r) = await (open, recent)
        if let o { openWatchIssues = o }
        if let r { recentWatchIssues = r }
    }

    /// Ready-made job plugins (from the computers' runners), loaded on demand.
    private(set) var jobTemplates: [JobTemplate] = []

    func loadJobTemplates() async {
        #if DEBUG
        if demo != nil { return }
        #endif
        guard let client = try? requireClient() else { return }
        if let list = try? await client.listJobTemplates() { jobTemplates = list }
    }

    // --- Today ---------------------------------------------------------------------------

    private(set) var briefing: Briefing?
    private(set) var reminders: [Reminder] = []
    private(set) var people: [Person] = []
    private(set) var todaySettings: TodaySettings?
    var dueReminderCount: Int { reminders.filter(\.isDue).count }

    /// Reloads the briefing, reminders, people and settings (each optional on an older hub).
    func loadToday() async {
        #if DEBUG
        if demo != nil { return }
        #endif
        guard let client = try? requireClient() else { return }
        async let b = try? client.today()
        async let r = try? client.listReminders()
        async let p = try? client.listPeople()
        async let s = try? client.todaySettings()
        let (briefing, reminders, people, settings) = await (b, r, p, s)
        if let briefing { self.briefing = briefing }
        if let reminders { self.reminders = reminders }
        if let people { self.people = people }
        if let settings { todaySettings = settings }
    }

    func saveReminder(id: String?, _ body: ReminderRequestBody) async throws -> String {
        var saved = ""
        try await perform { client in
            saved = try await (id == nil ? client.createReminder(body) : client.updateReminder(id: id!, body)).id
        }
        await loadToday()
        return saved
    }

    func deleteReminder(id: String) async throws {
        try await perform { client in try await client.deleteReminder(id: id) }
        await loadToday()
    }

    func doneReminder(id: String) async throws {
        try await perform { client in _ = try await client.doneReminder(id: id) }
        await loadToday()
    }

    func snoozeReminder(id: String, _ option: SnoozeOption) async throws {
        try await perform { client in _ = try await client.snoozeReminder(id: id, until: option.until()) }
        await loadToday()
    }

    func savePerson(id: String?, _ body: PersonRequestBody) async throws -> String {
        var saved = ""
        try await perform { client in
            saved = try await (id == nil ? client.createPerson(body) : client.updatePerson(id: id!, body)).id
        }
        await loadToday()
        return saved
    }

    func deletePerson(id: String) async throws {
        try await perform { client in try await client.deletePerson(id: id) }
        await loadToday()
    }

    func updateTodaySettings(_ update: TodaySettingsUpdate) async throws {
        try await perform { client in
            let s = try await client.updateTodaySettings(update)
            await MainActor.run { self.todaySettings = s }
        }
    }

    /// "Add with an agent": queues the short conversation; it starts within a minute.
    func startAssistant(text: String, kind: String?) async throws {
        try await perform { client in _ = try await client.startAssistant(text: text, kind: kind) }
        await refresh()
    }

    /// Reloads only the recently cleared issues: every refresh already brings the open ones.
    func loadRecentWatchIssues() async {
        #if DEBUG
        if demo != nil { return }
        #endif
        guard let client = try? requireClient() else { return }
        if let r = try? await client.listWatchIssues(state: "recent") { recentWatchIssues = r }
    }

    func loadWatchers(computerId: String) async {
        #if DEBUG
        if demo != nil { return }
        #endif
        guard !computerId.isEmpty, let client = try? requireClient() else { return }
        if let list = try? await client.listWatchers(computerId: computerId) { watchersByComputer[computerId] = list }
    }

    /// The installed watcher behind an issue (via its watch job's computer), if reported.
    func watcherInfo(for issue: WatchIssue) -> WatcherInfo? {
        guard let job = jobs.first(where: { $0.id == issue.jobId }), case let .watch(w) = job.action else { return nil }
        return watchersByComputer[w.computerId]?.first { $0.name == issue.watcher }
    }

    /// Resolve at the source; the watcher's computer does it within a minute.
    func resolveWatchIssue(_ issue: WatchIssue) async throws {
        try await perform { client in try await client.resolveWatchIssue(id: issue.id) }
        await loadWatchIssues()
    }

    /// Hand a needs-you or can't-fix issue to a new conversation.
    func retryWatchIssue(_ issue: WatchIssue) async throws {
        try await perform { client in try await client.retryWatchIssue(id: issue.id) }
        await loadWatchIssues()
    }

    /// Reloads `recentRuns`; nil when the hub has no `/api/runs` yet.
    func loadRecentRuns() async {
        #if DEBUG
        if demo != nil { return }
        #endif
        guard let client = try? requireClient() else { return }
        do {
            recentRuns = try await client.recentRuns(limit: 100)
        } catch TodoHubError.notFound {
            recentRuns = nil
        } catch {}
    }

    func updateJob(_ job: SchedulerJob, _ request: UpdateJobRequest) async throws {
        try await perform { client in _ = try await client.updateJob(id: job.id, request) }
    }

    func deleteJob(_ job: SchedulerJob) async throws {
        try await perform { client in try await client.deleteJob(id: job.id) }
    }

    func runJob(_ job: SchedulerJob) async throws {
        try await perform { client in _ = try await client.runJob(id: job.id) }
        await loadRecentRuns()
    }

    func jobRuns(_ job: SchedulerJob) async throws -> [JobRun] {
        try await requireClient().jobRuns(id: job.id, limit: 50)
    }

    func schedulerSettings() async throws -> SchedulerSettings {
        try await requireClient().schedulerSettings()
    }

    func updateSchedulerSettings(_ settings: SchedulerSettings) async throws {
        try await perform { client in _ = try await client.updateSchedulerSettings(settings) }
    }

    // MARK: Daily updates

    func projectUpdates(projectId: String, before: String?, limit: Int = 14) async throws -> [ProjectUpdate] {
        #if DEBUG
        if demo != nil { return [] }
        #endif
        return try await requireClient().projectUpdates(projectId: projectId, before: before, limit: limit)
    }

    func updateSummaries(projectId: String, day: String) async throws -> [UpdateSummary] {
        #if DEBUG
        if demo != nil { return [] }
        #endif
        return try await requireClient().updateSummaries(projectId: projectId, day: day)
    }

    func rewriteUpdate(projectId: String, day: String) async throws {
        try await perform { client in try await client.rewriteUpdate(projectId: projectId, day: day) }
    }

    // MARK: Weekly recap

    func weeklyRecaps(before: String? = nil, limit: Int = 4) async throws -> [WeeklyRecap] {
        #if DEBUG
        if demo != nil { return [] }
        #endif
        return try await requireClient().weeklyRecaps(before: before, limit: limit)
    }

    func rewriteWeekly(projectId: String, week: String) async throws {
        try await perform { client in try await client.rewriteWeekly(projectId: projectId, week: week) }
    }

    // MARK: Ideas

    func ideas(projectId: String, pending: Bool = false) async throws -> [Idea] {
        #if DEBUG
        if demo != nil { return [] }
        #endif
        return try await requireClient().listIdeas(projectId: projectId, pending: pending)
    }

    func createIdea(_ request: CreateIdeaRequest) async throws {
        try await perform { client in _ = try await client.createIdea(request) }
        await loadAllIdeas()
    }

    func updateIdea(_ idea: Idea, _ request: UpdateIdeaRequest) async throws {
        try await perform { client in _ = try await client.updateIdea(id: idea.id, request) }
        await loadAllIdeas()
    }

    func deleteIdea(_ idea: Idea) async throws {
        try await perform { client in try await client.deleteIdea(id: idea.id) }
        await loadAllIdeas()
    }

    /// The new todo's id.
    func ideaToTodo(_ idea: Idea) async throws -> String {
        var todoId = ""
        try await perform { client in todoId = try await client.ideaToTodo(id: idea.id) }
        // The caller opens the new todo next, so it must be in `todos` already.
        await refresh()
        return todoId
    }

    func shapeIdea(projectId: String, hint: String) async throws {
        try await perform { client in _ = try await client.shapeIdea(projectId: projectId, hint: hint) }
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

    /// Runs a hub mutation, then starts a refresh without waiting for it: the caller (a sheet
    /// closing, a field clearing) only needs the mutation itself. Throws the mutation's error.
    private func perform(_ body: (TodoHubClient) async throws -> Void) async throws {
        #if DEBUG
        if demo != nil { return } // screenshots only: nothing to change
        #endif
        guard let client = hubClient() else { throw TodoHubError.invalidBaseURL }
        guard !isOffline else { throw OfflineChangeError() }
        try await body(client)
        refreshSoon()
    }

    /// The background refresh after a change. It joins the coalescer like a live-update echo,
    /// so the change and its websocket event still cost one fetch.
    private func refreshSoon() {
        Task { await refresh(trigger: .background) }
    }

    /// Shows a todo the hub just returned, before the refresh confirms it.
    private func upsert(_ todo: Todo) {
        localChanges += 1
        if let index = todos.firstIndex(where: { $0.id == todo.id }) {
            todos[index] = todo
        } else {
            todos.append(todo)
        }
    }

    private func removeTodo(id: String) {
        guard todos.contains(where: { $0.id == id }) else { return }
        localChanges += 1
        todos.removeAll { $0.id == id }
    }

    private func upsert(_ computer: Computer) {
        localChanges += 1
        if let index = computers.firstIndex(where: { $0.id == computer.id }) {
            computers[index] = computer
        } else {
            computers.append(computer)
        }
    }

    /// Shows a project the hub just returned, in the hub's order (name ignoring case, then id).
    private func upsert(_ project: Project) {
        localChanges += 1
        projects.removeAll { $0.id == project.id }
        projects.append(project)
        projects.sort { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
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
        Set(conversations.values.map { ConversationIdentity(id: $0.id, todoId: $0.todoId, sessionId: $0.sessionId) })
    }

    private struct ConversationIdentity: Hashable {
        var id: String
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
        let mapped = Dictionary(conversations.map { (Self.storageKey($0), $0) }, uniquingKeysWith: { _, new in new })
        if self.conversations != mapped { self.conversations = mapped }
    }

    static func message(for error: Error) -> String {
        if let error = error as? TodoHubError { return error.userMessage }
        if let error = error as? SSHRemoteError { return error.userMessage }
        if error is KeychainPrivateKeyStoreError { return ComputerErrorText.message(for: error, computer: "the computer") }
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

/// Remembers per key that something was refused, and allows a new try after `interval`.
struct RetryAfter {
    var interval: TimeInterval = 300
    private var since: [String: Date] = [:]

    init(interval: TimeInterval = 300) { self.interval = interval }

    func isBlocked(_ key: String, now: Date = Date()) -> Bool {
        guard let refused = since[key] else { return false }
        return now.timeIntervalSince(refused) < interval
    }

    mutating func block(_ key: String, now: Date = Date()) {
        since[key] = now
    }
}
