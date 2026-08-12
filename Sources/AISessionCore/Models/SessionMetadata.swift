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

public extension SessionMetadata {
    enum TemplateError: Error, Equatable {
        /// The encoded JSON did not contain exactly one placeholder — meaning user-supplied
        /// text collided with it, so substituting would corrupt the document.
        case placeholderCollision
    }

    /// Token standing in for the `cli` entry while the JSON is encoded, then swapped for `%s`.
    static let cliPlaceholder = "__AI_REMOTE_CLI_PATH__"

    /// JSON for this session's metadata as a `printf` **format string** taking exactly one
    /// argument: the binary path resolved on the host.
    ///
    /// The binary path is only known remotely, so metadata cannot be fully encoded on the
    /// client. Every literal `%` is escaped to `%%` so user text such as a "100% done" title
    /// survives `printf` intact.
    static func printfTemplate(
        tool: AITool,
        cwd: String,
        title: String,
        startedAt: Date
    ) throws -> String {
        let templated = SessionMetadata(
            tool: tool, cwd: cwd, title: title, startedAt: startedAt, cli: [cliPlaceholder]
        )
        let json = String(decoding: try templated.jsonData(), as: UTF8.self)

        guard json.components(separatedBy: cliPlaceholder).count - 1 == 1 else {
            throw TemplateError.placeholderCollision
        }

        return json
            .replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: cliPlaceholder, with: "%s")
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
