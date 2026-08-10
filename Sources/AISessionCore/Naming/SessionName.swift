public struct SessionName: Hashable, Sendable {
    public let tool: AITool
    public let slug: String

    public init(tool: AITool, slug: String) {
        self.tool = tool
        self.slug = slug
    }

    public var tmuxName: String {
        "ai/\(tool.rawValue)/\(slug)"
    }

    public static func parse(_ tmuxName: String) -> SessionName? {
        let parts = tmuxName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "ai",
              let tool = AITool(rawValue: String(parts[1])),
              isValidSlug(String(parts[2]))
        else {
            return nil
        }
        return SessionName(tool: tool, slug: String(parts[2]))
    }

    public static func makeUnique(
        tool: AITool,
        slug: String,
        existing: Set<String>
    ) -> SessionName {
        let base = SessionName(tool: tool, slug: slug)
        if !existing.contains(base.tmuxName) {
            return base
        }

        var suffix = 2
        while true {
            let candidate = SessionName(tool: tool, slug: "\(slug)-\(suffix)")
            if !existing.contains(candidate.tmuxName) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty else { return false }
        return slug.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }
}
