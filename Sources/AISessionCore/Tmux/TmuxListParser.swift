public enum TmuxListParser {
    public static func parse(listSessionsOutput: String) -> (ai: [RemoteSession], other: [RemoteSession]) {
        var ai: [RemoteSession] = []
        var other: [RemoteSession] = []

        for line in listSessionsOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let tmuxName = extractSessionName(from: trimmed)
            guard !tmuxName.isEmpty else { continue }

            if let sessionName = SessionName.parse(tmuxName) {
                ai.append(
                    RemoteSession(
                        tmuxName: tmuxName,
                        tool: sessionName.tool,
                        slug: sessionName.slug,
                        cwd: nil,
                        isAIManaged: true
                    )
                )
            } else {
                other.append(
                    RemoteSession(
                        tmuxName: tmuxName,
                        tool: nil,
                        slug: tmuxName,
                        cwd: nil,
                        isAIManaged: false
                    )
                )
            }
        }

        return (ai: ai, other: other)
    }

    private static func extractSessionName(from line: String) -> String {
        if let colonRange = line.range(of: ": ") {
            return String(line[..<colonRange.lowerBound])
        }
        return line
    }
}
