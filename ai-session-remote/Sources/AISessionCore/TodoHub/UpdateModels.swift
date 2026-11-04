import Foundation

// Daily updates per project (`/api/projects/{id}/updates`): each morning a summary of the
// previous day's work (08:00 to 08:00 Sofia), written from per-conversation summaries,
// commits and completed todos, in the project's update style.

public struct ProjectUpdate: Codable, Hashable, Identifiable, Sendable {
    /// `YYYY-MM-DD`: the window starting 08:00 Sofia on that date.
    public var day: String
    /// Markdown.
    public var text: String
    public var commits: Int
    public var conversations: Int
    /// Conversations of that day that couldn't be summarized.
    public var failed: Int
    /// Computers that hadn't reported when it was written.
    public var waitingOn: [String]
    public var writtenAt: String
    /// A rewrite is pending (asked for, or a late summary came in).
    public var rewriting: Bool

    public var id: String { day }

    public init(day: String, text: String, commits: Int = 0, conversations: Int = 0, failed: Int = 0,
                waitingOn: [String] = [], writtenAt: String = "", rewriting: Bool = false) {
        self.day = day
        self.text = text
        self.commits = commits
        self.conversations = conversations
        self.failed = failed
        self.waitingOn = waitingOn
        self.writtenAt = writtenAt
        self.rewriting = rewriting
    }

    private enum CodingKeys: String, CodingKey {
        case day, text, commits, conversations, failed, waitingOn, writtenAt, rewriting
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        text = try c.decode(String.self, forKey: .text)
        commits = try c.decodeIfPresent(Int.self, forKey: .commits) ?? 0
        conversations = try c.decodeIfPresent(Int.self, forKey: .conversations) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        waitingOn = try c.decodeIfPresent([String].self, forKey: .waitingOn) ?? []
        writtenAt = try c.decodeIfPresent(String.self, forKey: .writtenAt) ?? ""
        rewriting = try c.decodeIfPresent(Bool.self, forKey: .rewriting) ?? false
    }
}

/// One conversation's summary for a day.
public struct UpdateSummary: Codable, Hashable, Identifiable, Sendable {
    public var tool: String
    public var sessionId: String
    /// Set when a todo links the conversation; otherwise it ran only in a terminal.
    public var todoId: String?
    public var title: String
    public var summary: String
    public var jiraKeys: [String]
    public var computer: String
    /// It couldn't be summarized; `summary` is empty.
    public var failed: Bool

    public var id: String { "\(tool):\(sessionId)" }

    private enum CodingKeys: String, CodingKey {
        case tool, sessionId, todoId, title, summary, jiraKeys, computer, failed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decode(String.self, forKey: .tool)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        todoId = try c.decodeIfPresent(String.self, forKey: .todoId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        jiraKeys = try c.decodeIfPresent([String].self, forKey: .jiraKeys) ?? []
        computer = try c.decodeIfPresent(String.self, forKey: .computer) ?? ""
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
    }
}

public enum UpdateDay {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let printer: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE d MMM"
        return f
    }()

    /// `older` added after `shown`, skipping days already there (a page loaded twice).
    public static func appending(_ shown: [ProjectUpdate], _ older: [ProjectUpdate]) -> [ProjectUpdate] {
        let days = Set(shown.map(\.day))
        return shown + older.filter { !days.contains($0.day) }
    }

    /// "Mon 2 Nov" for "2026-11-02"; anything else is returned as it is.
    public static func label(_ day: String) -> String {
        guard let date = parser.date(from: day) else { return day }
        return printer.string(from: date)
    }
}
