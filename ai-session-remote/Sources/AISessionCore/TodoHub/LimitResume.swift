import Foundation

/// What `ai-todo-status resume <tool> <id>` printed: `{"resumed": true}`, or
/// `{"resumed": false, "reason": "limit", "resets_at": "…"}` (exit 75).
public struct LimitResumeOutcome: Decodable, Equatable, Sendable {
    public var resumed: Bool
    /// limit, question, draft, busy, not_paused, closed, leased, no_session, hub_unavailable, unknown.
    public var reason: String?
    public var resetsAt: String?

    public init(resumed: Bool, reason: String? = nil, resetsAt: String? = nil) {
        self.resumed = resumed
        self.reason = reason
        self.resetsAt = resetsAt
    }

    /// Exit 0 and 75 carry JSON; anything else (an older helper, no JSON) is nil.
    public static func parse(stdout: String, exitCode: Int32) -> LimitResumeOutcome? {
        guard exitCode == 0 || exitCode == 75,
              let line = stdout.split(whereSeparator: \.isNewline).last,
              let data = String(line).data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(LimitResumeOutcome.self, from: data)
    }

    public var resetDate: Date? { resetsAt.flatMap { HubDates.date(from: $0) } }
}
