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
    var errorMessage: String?

    private let cache: TodoHubCache
    private var eventsTask: Task<Void, Never>?

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

    func refresh() async {
        guard let client = TodoHubSettings.makeClient() else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            async let todos = client.listTodos()
            async let conversations = client.listConversations()
            async let mappings = client.listSectionComputers()
            async let computers = client.listComputers()
            let (t, c, m, comps) = try await (todos, conversations, mappings, computers)
            apply(todos: t, conversations: c)
            sectionComputers = Dictionary(m.map { ($0.section, $0) }, uniquingKeysWith: { _, new in new })
            self.computers = comps
            isOffline = false
            let snapshot = TodoHubSnapshot(todos: t, conversations: c)
            try? cache.save(snapshot)
            cachedAt = snapshot.savedAt
        } catch TodoHubError.unreachable {
            isOffline = true
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Re-fetches on every server-side change until `stopLiveUpdates()`.
    func startLiveUpdates() {
        guard eventsTask == nil, let client = TodoHubSettings.makeClient() else { return }
        eventsTask = Task { [weak self] in
            for await _ in TodoHubEvents.refreshes(baseURL: client.baseURL, token: client.token) {
                await self?.refresh()
            }
        }
    }

    func stopLiveUpdates() {
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

    func addComputer(name: String, hostname: String, port: Int, username: String) async {
        await mutate { client in
            _ = try await client.createComputer(
                CreateComputerRequest(name: name, hostname: hostname, port: port, username: username)
            )
        }
    }

    func deleteComputer(_ computer: Computer) async {
        await mutate { client in try await client.deleteComputer(id: computer.id) }
    }

    func assign(_ section: TodoSection, computerID: String?, cwd: String) async {
        await mutate { client in
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
    /// The Claude conversation stays resumable: opening the todo again runs `claude --resume`.
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
        await refresh()
    }

    // MARK: Helpers

    private func mutate(_ body: (TodoHubClient) async throws -> Void) async {
        guard let client = TodoHubSettings.makeClient() else { return }
        guard !isOffline else {
            errorMessage = "The todo server is unreachable. Changes are disabled while offline."
            return
        }
        do {
            try await body(client)
            await refresh()
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
