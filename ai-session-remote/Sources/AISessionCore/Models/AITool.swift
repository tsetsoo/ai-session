public enum AITool: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case antigravity
    /// Interactive login-style shell inside tmux (not Plain SSH, which skips tmux).
    case shell

    /// Codex reviews approval requests automatically while keeping its workspace sandbox.
    public var defaultArguments: [String] {
        self == .codex ? ["--approve-for-me"] : []
    }

    func launchArguments(antigravityConversationID: String?) -> [String] {
        if self == .antigravity, let antigravityConversationID {
            return ["--conversation", antigravityConversationID]
        }
        return defaultArguments
    }

    public var defaultBinary: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "agent"
        case .antigravity: "agy"
        case .shell: "bash"
        }
    }
}
