public struct HostBinaryHealth: Sendable, Equatable, Codable {
    public let tmux: String?
    public let claude: String?
    public let codex: String?
    public let agent: String?
    public let shell: String?
    public let agy: String?

    public init(
        tmux: String?,
        claude: String?,
        codex: String?,
        agent: String?,
        shell: String?,
        agy: String? = nil
    ) {
        self.tmux = tmux
        self.claude = claude
        self.codex = codex
        self.agent = agent
        self.shell = shell
        self.agy = agy
    }

    public var tmuxOK: Bool { tmux != nil }
    public var claudeOK: Bool { claude != nil }
    public var codexOK: Bool { codex != nil }
    public var agentOK: Bool { agent != nil }
    public var agyOK: Bool { agy != nil }
}
