import Foundation

/// Last successful fetch from the hub, shown read-only while the hub is unreachable.
public struct TodoHubSnapshot: Codable, Equatable, Sendable {
    public var todos: [Todo]
    public var conversations: [Conversation]
    /// Absent in cache files written before projects existed.
    public var projects: [Project]
    public var savedAt: Date

    public init(todos: [Todo], conversations: [Conversation], projects: [Project] = [], savedAt: Date = .now) {
        self.todos = todos
        self.conversations = conversations
        self.projects = projects
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case todos, conversations, projects, savedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todos = try c.decode([Todo].self, forKey: .todos)
        conversations = try c.decode([Conversation].self, forKey: .conversations)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        savedAt = try c.decode(Date.self, forKey: .savedAt)
    }
}

/// Stores one `TodoHubSnapshot` as a JSON file (by default in Application Support).
public struct TodoHubCache: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func applicationSupport(fileName: String = "todo-hub-cache.json") -> TodoHubCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // The unsandboxed Mac app shares ~/Library/Application Support with every other app,
        // so keep the file in a folder of its own.
        let folder = Bundle.main.bundleIdentifier ?? "AISessionRemote"
        return TodoHubCache(fileURL: base.appendingPathComponent(folder).appendingPathComponent(fileName))
    }

    public func load() -> TodoHubSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TodoHubSnapshot.self, from: data)
    }

    public func save(_ snapshot: TodoHubSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
