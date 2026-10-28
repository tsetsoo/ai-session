public enum AITool: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    /// Interactive login-style shell inside tmux (not Plain SSH, which skips tmux).
    case shell

    /// Codex reviews approval requests automatically while keeping its workspace sandbox.
    public var defaultArguments: [String] {
        self == .codex ? ["--approve-for-me"] : []
    }

    public var defaultBinary: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "agent"
        case .shell: "bash"
        }
    }
}
