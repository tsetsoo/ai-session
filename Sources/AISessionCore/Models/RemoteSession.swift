public struct RemoteSession: Equatable, Sendable {
    public let tmuxName: String
    public let tool: AITool?
    public let slug: String
    public let cwd: String?
    public let isAIManaged: Bool

    public init(
        tmuxName: String,
        tool: AITool?,
        slug: String,
        cwd: String?,
        isAIManaged: Bool
    ) {
        self.tmuxName = tmuxName
        self.tool = tool
        self.slug = slug
        self.cwd = cwd
        self.isAIManaged = isAIManaged
    }
}
