public enum AITool: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case cursor

    public var defaultBinary: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "agent"
        }
    }
}
