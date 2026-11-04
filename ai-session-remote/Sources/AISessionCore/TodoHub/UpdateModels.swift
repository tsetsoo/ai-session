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
    /// Computers that hadn't reported when it was written.
    public var waitingOn: [String]
    public var writtenAt: String
    /// A rewrite is pending (asked for, or a late summary came in).
    public var rewriting: Bool

    public var id: String { day }

    public init(day: String, text: String, commits: Int = 0, conversations: Int = 0, waitingOn: [String] = [],
                writtenAt: String = "", rewriting: Bool = false) {
        self.day = day
        self.text = text
        self.commits = commits
        self.conversations = conversations
        self.waitingOn = waitingOn
        self.writtenAt = writtenAt
        self.rewriting = rewriting
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

    public var id: String { "\(tool):\(sessionId)" }
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

    /// "Mon 2 Nov" for "2026-11-02"; anything else is returned as it is.
    public static func label(_ day: String) -> String {
        guard let date = parser.date(from: day) else { return day }
        return printer.string(from: date)
    }
}
