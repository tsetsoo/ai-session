public struct SessionName: Hashable, Sendable {
    public let tool: AITool
    public let slug: String

    public init?(tool: AITool, slug: String) {
        guard Self.isValidSlug(slug) else { return nil }
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
              let tool = AITool(rawValue: String(parts[1]))
        else {
            return nil
        }
        return SessionName(tool: tool, slug: String(parts[2]))
    }

    public static func makeUnique(
        tool: AITool,
        slug: String,
        existing: Set<String>
    ) -> SessionName? {
        guard let base = SessionName(tool: tool, slug: slug) else { return nil }
        if !existing.contains(base.tmuxName) {
            return base
        }

        var suffix = 2
        while true {
            guard let candidate = SessionName(tool: tool, slug: "\(slug)-\(suffix)") else {
                return nil
            }
            if !existing.contains(candidate.tmuxName) {
                return candidate
            }
            suffix += 1
        }
    }

    /// Exposed publicly so UI layers (e.g. `NewSessionSheet`) can validate a slug before
    /// submitting it, instead of only finding out it's invalid after a round-trip to the host.
    public static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty else { return false }
        for scalar in slug.unicodeScalars {
            let value = scalar.value
            let isLowercaseASCII = value >= 0x61 && value <= 0x7A
            let isDigitASCII = value >= 0x30 && value <= 0x39
            let isHyphen = value == 0x2D
            guard isLowercaseASCII || isDigitASCII || isHyphen else { return false }
        }
        return true
    }
}
