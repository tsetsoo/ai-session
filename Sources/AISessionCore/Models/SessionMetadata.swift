import Foundation

public struct SessionMetadata: Codable, Equatable, Sendable {
    public let tool: AITool
    public let cwd: String
    public let title: String
    public let startedAt: Date
    public let cli: [String]

    public init(
        tool: AITool,
        cwd: String,
        title: String,
        startedAt: Date,
        cli: [String]
    ) {
        self.tool = tool
        self.cwd = cwd
        self.title = title
        self.startedAt = startedAt
        self.cli = cli
    }
}

/// JSON helpers use ISO-8601 dates (with fractional seconds when the encoder emits them).
public extension SessionMetadata {
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func from(jsonData: Data) throws -> SessionMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionMetadata.self, from: jsonData)
    }
}

public enum SessionMetadataStore {
    public static func filename(for tmuxName: String) -> String {
        tmuxName.replacingOccurrences(of: "/", with: "__") + ".json"
    }

    public static func remotePath(for tmuxName: String) -> String {
        "~/.ai-remote/sessions/\(filename(for: tmuxName))"
    }
}
