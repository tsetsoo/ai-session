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

private enum SessionMetadataJSON {
    static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// JSON helpers use ISO-8601 dates with fractional seconds.
public extension SessionMetadata {
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(SessionMetadataJSON.iso8601Fractional.string(from: date))
        }
        return try encoder.encode(self)
    }

    static func from(jsonData: Data) throws -> SessionMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = SessionMetadataJSON.iso8601Fractional.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date with fractional seconds: \(string)"
                )
            }
            return date
        }
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
