public enum AITool: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    /// Interactive login-style shell inside tmux (not Plain SSH, which skips tmux).
    case shell

    public var defaultBinary: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "agent"
        case .shell: "bash"
        }
    }
}
