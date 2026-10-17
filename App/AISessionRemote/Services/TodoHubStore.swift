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
    /// The background issue is a rejected token, fixed in Settings → Todo server.
    private(set) var tokenRejected = false

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
            cachedAt = snapshot.savedAt
        }
    }

    var isConfigured: Bool { TodoHubSettings.isConfigured }

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
            let (t, c, m, comps) = try await (todos, conversations, mappings, computers)
            // A refresh that started later has newer data; don't overwrite it.
            guard generation == refreshGeneration else { return }
            apply(todos: t, conversations: c)
            sectionComputers = Dictionary(m.map { ($0.section, $0) }, uniquingKeysWith: { _, new in new })
            self.computers = comps
            isOffline = false
            backgroundIssue = nil
            tokenRejected = false
            let snapshot = TodoHubSnapshot(todos: t, conversations: c)
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

    #if DEBUG
    /// Fills the store without touching the hub or the cache (demo launches and tests).
    func seedForDemo(todos: [Todo], conversations: [Conversation],
                     sectionComputers: [SectionComputer], computers: [Computer]) {
        apply(todos: todos, conversations: conversations)
        self.sectionComputers = Dictionary(sectionComputers.map { ($0.section, $0) }, uniquingKeysWith: { _, new in new })
        self.computers = computers
        hasLoadedOnce = true
        // As if just fetched: the sync line reads "Synced · just now", not the real cache's age.
        cachedAt = .now
    }
    #endif

    // MARK: Todos

    func createTodo(section: TodoSection, title: String) async {
        await mutate { client in
            _ = try await client.createTodo(CreateTodoRequest(section: section, title: title))
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

    // MARK: Helpers

    private struct OfflineChangeError: LocalizedError {
        var errorDescription: String? { "The todo server is unreachable. Changes are disabled while offline." }
    }

    /// Runs a hub mutation, then refreshes. Throws the mutation's error.
    private func perform(_ body: (TodoHubClient) async throws -> Void) async throws {
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
