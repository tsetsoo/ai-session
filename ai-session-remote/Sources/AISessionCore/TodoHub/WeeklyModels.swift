import Foundation

// Weekly recap (`GET /api/weekly`): per finished week (Mon 08:00 to Mon 08:00 Sofia) each project's
// headline and wins, totals, and the scheduled jobs' tallies.

/// Totals across a week's sections and jobs.
public struct WeeklyTotals: Codable, Hashable, Sendable {
    public var commits: Int
    public var conversations: Int
    public var runs: Int

        public init(commits: Int = 0, conversations: Int = 0, runs: Int = 0) {
        self.commits = commits
        self.conversations = conversations
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey {
        case commits, conversations, runs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commits = try c.decodeIfPresent(Int.self, forKey: .commits) ?? 0
        conversations = try c.decodeIfPresent(Int.self, forKey: .conversations) ?? 0
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
    }
}

/// One day of a project's week: `update`, `quiet`, `failed`, `missing` or `untracked`.
public struct WeeklyDayState: Codable, Hashable, Identifiable, Sendable {
    public var day: String
    public var state: String

    public var id: String { day }

    public init(day: String, state: String = "") {
        self.day = day
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case day, state
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
    }
}

/// One project's recap for a week. `wins` is Markdown.
public struct WeeklySection: Codable, Hashable, Identifiable, Sendable {
    public var projectId: String
    public var projectName: String
    public var headline: String
    public var wins: String
    public var failed: Bool
    public var rewriting: Bool
    public var commits: Int
    public var conversations: Int
    public var daysWithWork: Int
    public var days: [WeeklyDayState]
    public var writtenAt: String

    public var id: String { projectId }

    public init(projectId: String, projectName: String = "", headline: String = "", wins: String = "", failed: Bool = false, rewriting: Bool = false, commits: Int = 0, conversations: Int = 0, daysWithWork: Int = 0, days: [WeeklyDayState] = [], writtenAt: String = "") {
        self.projectId = projectId
        self.projectName = projectName
        self.headline = headline
        self.wins = wins
        self.failed = failed
        self.rewriting = rewriting
        self.commits = commits
        self.conversations = conversations
        self.daysWithWork = daysWithWork
        self.days = days
        self.writtenAt = writtenAt
    }

    private enum CodingKeys: String, CodingKey {
        case projectId, projectName, headline, wins, failed, rewriting, commits, conversations, daysWithWork, days, writtenAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try c.decode(String.self, forKey: .projectId)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
        wins = try c.decodeIfPresent(String.self, forKey: .wins) ?? ""
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        rewriting = try c.decodeIfPresent(Bool.self, forKey: .rewriting) ?? false
        commits = try c.decodeIfPresent(Int.self, forKey: .commits) ?? 0
        conversations = try c.decodeIfPresent(Int.self, forKey: .conversations) ?? 0
        daysWithWork = try c.decodeIfPresent(Int.self, forKey: .daysWithWork) ?? 0
        days = try c.decodeIfPresent([WeeklyDayState].self, forKey: .days) ?? []
        writtenAt = try c.decodeIfPresent(String.self, forKey: .writtenAt) ?? ""
    }
}

/// One scheduled run still present for a job.
public struct WeeklyRunLine: Codable, Hashable, Identifiable, Sendable {
    public var runId: String
    public var dueAt: String
    public var state: String
    public var outcome: String
    public var todoId: String?

    public var id: String { runId }

    public init(runId: String, dueAt: String = "", state: String = "", outcome: String = "", todoId: String? = nil) {
        self.runId = runId
        self.dueAt = dueAt
        self.state = state
        self.outcome = outcome
        self.todoId = todoId
    }

    private enum CodingKeys: String, CodingKey {
        case runId, dueAt, state, outcome, todoId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(String.self, forKey: .runId)
        dueAt = try c.decodeIfPresent(String.self, forKey: .dueAt) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        todoId = try c.decodeIfPresent(String.self, forKey: .todoId)
    }
}

/// One job's week: tallies and the runs still present. Watchers count quiet and skipped runs as checks.
public struct WeeklyJob: Codable, Hashable, Identifiable, Sendable {
    public var jobId: String
    public var name: String
    public var projectName: String
    public var isWatch: Bool
    public var runs: Int
    public var done: Int
    public var failed: Int
    public var skipped: Int
    public var checks: Int
    public var findings: Int
    public var lines: [WeeklyRunLine]

    public var id: String { jobId }

    public init(jobId: String, name: String = "", projectName: String = "", isWatch: Bool = false, runs: Int = 0, done: Int = 0, failed: Int = 0, skipped: Int = 0, checks: Int = 0, findings: Int = 0, lines: [WeeklyRunLine] = []) {
        self.jobId = jobId
        self.name = name
        self.projectName = projectName
        self.isWatch = isWatch
        self.runs = runs
        self.done = done
        self.failed = failed
        self.skipped = skipped
        self.checks = checks
        self.findings = findings
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey {
        case jobId, name, projectName, isWatch, runs, done, failed, skipped, checks, findings, lines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(String.self, forKey: .jobId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        isWatch = try c.decodeIfPresent(Bool.self, forKey: .isWatch) ?? false
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        checks = try c.decodeIfPresent(Int.self, forKey: .checks) ?? 0
        findings = try c.decodeIfPresent(Int.self, forKey: .findings) ?? 0
        lines = try c.decodeIfPresent([WeeklyRunLine].self, forKey: .lines) ?? []
    }
}

/// The scheduled jobs' week.
public struct WeeklyJobs: Codable, Hashable, Sendable {
    public var runs: Int
    public var done: Int
    public var failed: Int
    public var skipped: Int
    public var todosCreated: Int
    public var conversationsStarted: Int
    public var findings: Int
    public var jobs: [WeeklyJob]

        public init(runs: Int = 0, done: Int = 0, failed: Int = 0, skipped: Int = 0, todosCreated: Int = 0, conversationsStarted: Int = 0, findings: Int = 0, jobs: [WeeklyJob] = []) {
        self.runs = runs
        self.done = done
        self.failed = failed
        self.skipped = skipped
        self.todosCreated = todosCreated
        self.conversationsStarted = conversationsStarted
        self.findings = findings
        self.jobs = jobs
    }

    private enum CodingKeys: String, CodingKey {
        case runs, done, failed, skipped, todosCreated, conversationsStarted, findings, jobs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        todosCreated = try c.decodeIfPresent(Int.self, forKey: .todosCreated) ?? 0
        conversationsStarted = try c.decodeIfPresent(Int.self, forKey: .conversationsStarted) ?? 0
        findings = try c.decodeIfPresent(Int.self, forKey: .findings) ?? 0
        jobs = try c.decodeIfPresent([WeeklyJob].self, forKey: .jobs) ?? []
    }
}

/// A finished week. `week` is the Monday, `YYYY-MM-DD`. `jobs` is null when no snapshot exists.
public struct WeeklyRecap: Codable, Hashable, Identifiable, Sendable {
    public var week: String
    public var totals: WeeklyTotals
    public var sections: [WeeklySection]
    public var jobs: WeeklyJobs?

    public var id: String { week }

    public init(week: String, totals: WeeklyTotals = WeeklyTotals(), sections: [WeeklySection] = [], jobs: WeeklyJobs? = nil) {
        self.week = week
        self.totals = totals
        self.sections = sections
        self.jobs = jobs
    }

    private enum CodingKeys: String, CodingKey {
        case week, totals, sections, jobs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = try c.decode(String.self, forKey: .week)
        totals = try c.decodeIfPresent(WeeklyTotals.self, forKey: .totals) ?? WeeklyTotals()
        sections = try c.decodeIfPresent([WeeklySection].self, forKey: .sections) ?? []
        jobs = try c.decodeIfPresent(WeeklyJobs.self, forKey: .jobs)
    }
}

extension WeeklyRecap {
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "Week of Mon 2 Nov".
    public var label: String { "Week of \(UpdateDay.label(week))" }

    /// "Mon 2 Nov 08:00 → Mon 9 Nov 08:00".
    public var windowLabel: String {
        guard let start = Self.parser.date(from: week), let end = Self.utc.date(byAdding: .day, value: 7, to: start) else {
            return week
        }
        let endDay = UpdateDay.label(Self.parser.string(from: end))
        return "\(UpdateDay.label(week)) 08:00 → \(endDay) 08:00"
    }
}

extension WeeklySection {
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE"
        return f
    }()

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Days that count: 7 minus the days before daily updates were tracked.
    public var trackedDays: Int { 7 - days.filter { $0.state == "untracked" }.count }

    /// Days that had a daily update written.
    public var updateCount: Int { days.filter { $0.state == "update" }.count }

    /// "5 conversations · 12 commits · 4 of 6 days".
    public var countLine: String {
        "\(Self.plural(conversations, "conversation")) · \(Self.plural(commits, "commit")) · \(daysWithWork) of \(trackedDays) days"
    }

    /// "Thu and Fri missing · Wed couldn't be written", or nil when nothing is missing or failed.
    public var gapsCaption: String? {
        let missing = days.filter { $0.state == "missing" }.map { Self.weekdayName($0.day) }
        let failed = days.filter { $0.state == "failed" }.map { Self.weekdayName($0.day) }
        var parts: [String] = []
        if !missing.isEmpty { parts.append("\(Self.list(missing)) missing") }
        if !failed.isEmpty { parts.append("\(Self.list(failed)) couldn't be written") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Thu" for "2026-11-05" (read in UTC, as `UpdateDay` does).
    public static func weekdayName(_ day: String) -> String {
        guard let date = parser.date(from: day) else { return day }
        return weekday.string(from: date)
    }

    /// "Mon", "Mon and Tue", "Mon, Tue and Thu".
    public static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    public static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

extension WeeklyRecap {
    /// Monday in Sofia, before 23:59: when the phone's Today shows a "Last week's recap" row.
    public static func isRecapDay(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TodayTime.zone
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        return c.weekday == 2 && !(c.hour == 23 && (c.minute ?? 0) >= 59)
    }

    /// Daily updates are kept 90 days: a day key older than Sofia's today minus 90 can't be opened.
    public static func isDayKept(_ day: String, now: Date = .now) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TodayTime.zone
        guard let cutoff = calendar.date(byAdding: .day, value: -90, to: now) else { return true }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TodayTime.zone
        f.dateFormat = "yyyy-MM-dd"
        return day >= f.string(from: cutoff)
    }
}
