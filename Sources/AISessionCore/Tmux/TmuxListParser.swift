import Foundation

public enum TmuxListParser {
    private struct AgentStatusPayload: Decodable {
        let status: SessionActivityStatus?
    }

    public static func parse(
        listSessionsOutput: String,
        now: Date = Date()
    ) -> (ai: [RemoteSession], other: [RemoteSession]) {
        var ai: [RemoteSession] = []
        var other: [RemoteSession] = []

        for line in listSessionsOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
            let tmuxName = extractSessionName(from: String(fields[0]))
            guard !tmuxName.isEmpty else { continue }
            let activityDate = fields.count > 1 ? unixDate(String(fields[1])) : nil
            let status = activityDate.map { now.timeIntervalSince($0) <= 45 ? SessionActivityStatus.busy : .idle } ?? .unknown

            if let sessionName = SessionName.parse(tmuxName) {
                ai.append(
                    RemoteSession(
                        tmuxName: tmuxName,
                        tool: sessionName.tool,
                        slug: sessionName.slug,
                        cwd: nil,
                        isAIManaged: true,
                        status: status,
                        lastActivityAt: activityDate
                    )
                )
            } else {
                other.append(
                    RemoteSession(
                        tmuxName: tmuxName,
                        tool: nil,
                        slug: tmuxName,
                        cwd: nil,
                        isAIManaged: false,
                        status: status,
                        lastActivityAt: activityDate
                    )
                )
            }
        }

        return (ai: ai, other: other)
    }

    public static func parseAgentStatuses(output: String) -> [String: SessionActivityStatus] {
        var statuses: [String: SessionActivityStatus] = [:]
        var filename: String?
        var json = ""

        func consume() {
            guard let filename, let data = json.data(using: .utf8) else { return }
            let decoder = JSONDecoder()
            guard let object = try? decoder.decode(AgentStatusPayload.self, from: data),
                  let status = object.status,
                  status != .unknown else { return }
            let base = filename.hasSuffix(".json") ? String(filename.dropLast(5)) : filename
            statuses[base.replacingOccurrences(of: "__", with: "/")] = status
        }

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("---"), line.hasSuffix("---") {
                consume()
                filename = String(line.dropFirst(3).dropLast(3))
                json = ""
            } else if filename != nil {
                json += line
            }
        }
        consume()
        return statuses
    }

    public static func applyAgentStatuses(
        _ statuses: [String: SessionActivityStatus],
        to sessions: (ai: [RemoteSession], other: [RemoteSession])
    ) -> (ai: [RemoteSession], other: [RemoteSession]) {
        func update(_ session: RemoteSession) -> RemoteSession {
            guard let status = statuses[session.tmuxName] else { return session }
            return RemoteSession(
                tmuxName: session.tmuxName, tool: session.tool, slug: session.slug,
                cwd: session.cwd, isAIManaged: session.isAIManaged,
                status: status, lastActivityAt: session.lastActivityAt
            )
        }
        return (sessions.ai.map(update), sessions.other.map(update))
    }

    private static func unixDate(_ value: String) -> Date? {
        guard let seconds = Double(value.trimmingCharacters(in: .whitespaces)),
              seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func extractSessionName(from line: String) -> String {
        if let colonRange = line.range(of: ": ") {
            return String(line[..<colonRange.lowerBound])
        }
        return line
    }
}
