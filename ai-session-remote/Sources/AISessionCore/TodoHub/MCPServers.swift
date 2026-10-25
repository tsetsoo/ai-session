import Foundation

/// One MCP server file on a host, as `ai-todo-mcp list --json` reports it.
public struct MCPServer: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    /// `nil` when the file has an error.
    public var kind: String?
    public var summary: String
    /// Why the file can't be used, if it can't.
    public var error: String?

    public var id: String { name }

    public init(name: String, kind: String? = nil, summary: String = "", error: String? = nil) {
        self.name = name
        self.kind = kind
        self.summary = summary
        self.error = error
    }

    public static func decodeList(_ data: Data) throws -> [MCPServer] {
        try JSONDecoder().decode([MCPServer].self, from: data)
    }
}

/// A PATCH field for an MCP default: set to a list (possibly empty), or clear back to "not set".
/// Wrap it in an `Optional` for "unchanged", which omits the key.
public enum MCPDefaultChange: Sendable, Equatable {
    case set([String])
    /// Sends an explicit JSON `null`.
    case clear
}

extension KeyedEncodingContainer {
    mutating func encodeMCPDefault(_ change: MCPDefaultChange?, forKey key: Key) throws {
        switch change {
        case nil: break
        case .clear?: try encodeNil(forKey: key)
        case let .set(names)?: try encode(names, forKey: key)
        }
    }
}

public enum MCPSelection {
    /// What a new conversation starts with: the project's default, else the computer's.
    /// `nil` means not managed.
    public static func initial(project: Project?, computer: Computer) -> [String]? {
        project?.mcpDefault ?? computer.mcpDefault
    }
}
