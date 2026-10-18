public struct HostBinaryHealth: Sendable, Equatable, Codable {
    public let tmux: String?
    public let claude: String?
    public let codex: String?
    public let agent: String?
    public let shell: String?

    public init(
        tmux: String?,
        claude: String?,
        codex: String?,
        agent: String?,
        shell: String?
    ) {
        self.tmux = tmux
        self.claude = claude
        self.codex = codex
        self.agent = agent
        self.shell = shell
    }

    public var tmuxOK: Bool { tmux != nil }
    public var claudeOK: Bool { claude != nil }
    public var codexOK: Bool { codex != nil }
    public var agentOK: Bool { agent != nil }
    public var shellOK: Bool { shell != nil }
}
