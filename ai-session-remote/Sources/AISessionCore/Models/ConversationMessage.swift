import Foundation

/// What a tool step did, from `ai-todo-transcript --activity`. Unknown kinds read as `other`.
public enum ActivityKind: String, Decodable, Sendable {
    case read, edit, run, search, other

    public init(from decoder: Decoder) throws {
        self = ActivityKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

/// Saved user/assistant text, without terminal line wrapping or padding. Keep text verbatim
/// so copying a message preserves blank lines, indentation and trailing spaces. With
/// `--activity`, tool steps arrive as `activity` entries with an empty text.
public struct ConversationMessage: Decodable, Identifiable, Equatable, Sendable {
    public enum Role: String, Decodable, Sendable {
        case user, assistant, activity
    }

    public let id: String
    public let role: Role
    public let text: String
    public let time: Date?
    public let kind: ActivityKind?
    /// The file, command or query a step acted on; the tool's name when it had none.
    public let target: String?
    /// The tool a step called ("Agent", "spawn_agent"); nil from helpers that predate it.
    public let name: String?

    public init(id: String, role: Role, text: String, time: Date? = nil, kind: ActivityKind? = nil, target: String? = nil, name: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.time = time
        self.kind = kind
        self.target = target
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, time, kind, target, name }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        time = (try container.decodeIfPresent(String.self, forKey: .time)).flatMap(Self.parseTime)
        kind = try container.decodeIfPresent(ActivityKind.self, forKey: .kind)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    /// The transcript script's `--json` output, with or without `--activity`.
    public static func decodeList(_ data: Data) throws -> [ConversationMessage] {
        try JSONDecoder().decode([ConversationMessage].self, from: data)
    }

    /// The transcript line of the last entry (an `--activity` id is `<line>.<part>`), to fetch only
    /// what came after it. Nil when there is nothing yet, or the ids aren't line-based (Cursor's
    /// `<file>.<line>.<part>`, plain `--json` indexes).
    public static func lastLine(of entries: [ConversationMessage]) -> Int? {
        guard let id = entries.last?.id else { return nil }
        let parts = id.split(separator: ".")
        guard parts.count == 2 else { return nil }
        return Int(parts[0])
    }

    /// Claude writes fractional seconds; Codex may not.
    static func parseTime(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
