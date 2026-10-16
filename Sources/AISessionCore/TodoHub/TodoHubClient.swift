import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TodoHubError: Error, Equatable, Sendable {
    case invalidBaseURL
    /// 401: missing or wrong API token.
    case unauthorized
    /// 404 with the server's message (e.g. "Todo has no conversation").
    case notFound(String)
    /// 409 with the server's message (e.g. "Section I has no computer assigned").
    case conflict(String)
    case badRequest(String)
    case server(status: Int, message: String)
    /// The hub could not be reached (offline, DNS, Tailscale down, timeout).
    case unreachable(String)
    case decoding(String)

    public var userMessage: String {
        switch self {
        case .invalidBaseURL: "The todo server URL is invalid."
        case .unauthorized: "The todo server rejected the API token."
        case let .notFound(message), let .conflict(message), let .badRequest(message): message
        case let .server(status, message): "Server error \(status): \(message)"
        case let .unreachable(message): "Could not reach the todo server: \(message)"
        case let .decoding(message): "Unexpected response from the todo server: \(message)"
        }
    }
}

/// HTTP client for the todo-app server (`/api`). The server only stores data; SSH to the
/// computers happens elsewhere in the app.
public struct TodoHubClient: Sendable {
    public let baseURL: URL
    public let token: String?
    private let session: URLSession

    /// - Parameter baseURL: server root, e.g. `http://100.118.255.23:8080` (no `/api`).
    public init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.session = session
    }

    /// Parses user input like `100.1.2.3:8080` or `http://pi:8080/` into a base URL.
    public static func baseURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/api") { text.removeLast(4) }
        guard let url = URL(string: text), url.host != nil,
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    // MARK: Health

    /// Unauthenticated liveness check.
    public func health() async throws {
        _ = try await send("GET", "/api/health", authorized: false)
    }

    // MARK: Todos

    public func listTodos(section: TodoSection? = nil, filter: TodoListFilter? = nil) async throws -> [Todo] {
        var query: [URLQueryItem] = []
        if let section { query.append(URLQueryItem(name: "section", value: section.rawValue)) }
        if let filter { query.append(URLQueryItem(name: "show", value: filter.rawValue)) }
        return try await decode([Todo].self, send("GET", "/api/todos", query: query))
    }

    public func createTodo(_ request: CreateTodoRequest) async throws -> Todo {
        try await decode(Todo.self, send("POST", "/api/todos", body: request))
    }

    public func updateTodo(id: String, _ request: UpdateTodoRequest) async throws -> Todo {
        try await decode(Todo.self, send("PATCH", "/api/todos/\(escape(id))", body: request))
    }

    public func toggleTodo(id: String) async throws -> Todo {
        try await decode(Todo.self, send("POST", "/api/todos/\(escape(id))/toggle"))
    }

    public func deleteTodo(id: String) async throws {
        _ = try await send("DELETE", "/api/todos/\(escape(id))")
    }

    // MARK: Computers and section mapping

    public func listComputers() async throws -> [Computer] {
        try await decode([Computer].self, send("GET", "/api/computers"))
    }

    public func createComputer(_ request: CreateComputerRequest) async throws -> Computer {
        try await decode(Computer.self, send("POST", "/api/computers", body: request))
    }

    public func deleteComputer(id: String) async throws {
        _ = try await send("DELETE", "/api/computers/\(escape(id))")
    }

    public func listSectionComputers() async throws -> [SectionComputer] {
        try await decode([SectionComputer].self, send("GET", "/api/sections/computers"))
    }

    public func setSectionComputer(_ section: TodoSection, _ request: SetSectionComputerRequest) async throws -> SectionComputer {
        try await decode(SectionComputer.self, send("PUT", "/api/sections/\(section.rawValue)/computer", body: request))
    }

    public func clearSectionComputer(_ section: TodoSection) async throws {
        _ = try await send("DELETE", "/api/sections/\(section.rawValue)/computer")
    }

    // MARK: Conversations

    public func listConversations() async throws -> [Conversation] {
        try await decode([Conversation].self, send("GET", "/api/conversations"))
    }

    /// Returns `nil` when the todo has no conversation yet.
    public func conversation(todoId: String) async throws -> Conversation? {
        do {
            return try await decode(Conversation.self, send("GET", "/api/todos/\(escape(todoId))/conversation"))
        } catch TodoHubError.notFound {
            return nil
        }
    }

    /// Get-or-create. Throws `.conflict` when the todo's section has no computer.
    public func openConversation(todoId: String) async throws -> Conversation {
        try await decode(Conversation.self, send("POST", "/api/todos/\(escape(todoId))/conversation"))
    }

    /// Marks the conversation closed. Kill the tmux session on the computer first.
    public func closeConversation(todoId: String) async throws -> Conversation {
        try await decode(Conversation.self, send("POST", "/api/todos/\(escape(todoId))/conversation/close"))
    }

    /// Forgets the todo's conversation on the hub (the next open starts a new one). Delete the
    /// conversation on the computer first if it should go away there too.
    public func deleteConversation(todoId: String) async throws {
        _ = try await send("DELETE", "/api/todos/\(escape(todoId))/conversation")
    }

    /// Links an existing conversation to a todo. Throws `.conflict` when the todo already has
    /// one (pass `replace: true` to swap it) or the conversation belongs to another todo.
    public func linkConversation(
        todoId: String,
        _ request: LinkConversationRequest,
        replace: Bool = false
    ) async throws -> Conversation {
        let query = replace ? [URLQueryItem(name: "replace", value: "true")] : []
        return try await decode(
            Conversation.self,
            send("POST", "/api/todos/\(escape(todoId))/conversation/link", query: query, body: request)
        )
    }

    /// Creates a todo that is already linked to an existing conversation.
    public func createTodoFromConversation(_ request: TodoFromConversationRequest) async throws -> TodoWithConversation {
        try await decode(TodoWithConversation.self, send("POST", "/api/todos/from-conversation", body: request))
    }

    // MARK: Transport

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? segment
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try Self.makeDecoder().decode(type, from: data)
        } catch {
            throw TodoHubError.decoding(String(describing: error))
        }
    }

    private struct NoBody: Encodable {}

    private func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        authorized: Bool = true
    ) async throws -> Data {
        try await send(method, path, query: query, body: Optional<NoBody>.none, authorized: authorized)
    }

    private func send<Body: Encodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Body?,
        authorized: Bool = true
    ) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TodoHubError.invalidBaseURL
        }
        components.percentEncodedPath = components.percentEncodedPath + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw TodoHubError.invalidBaseURL }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.makeEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TodoHubError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TodoHubError.unreachable("No HTTP response")
        }
        guard !(200..<300).contains(http.statusCode) else { return data }

        let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        switch http.statusCode {
        case 401: throw TodoHubError.unauthorized
        case 400: throw TodoHubError.badRequest(message)
        case 404: throw TodoHubError.notFound(message)
        case 409: throw TodoHubError.conflict(message)
        default: throw TodoHubError.server(status: http.statusCode, message: message)
        }
    }
}
