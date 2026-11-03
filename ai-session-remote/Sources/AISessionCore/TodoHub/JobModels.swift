import Foundation

// Scheduler jobs (`/api/jobs`): when a job runs (trigger), what it does (action) and its runs.
// The hub's JSON is tagged (`kind`, `mode`); keys arrive camelCased through the client's
// decoder and leave snake_cased through its encoder.

/// When a job runs.
public enum JobTrigger: Codable, Equatable, Hashable, Sendable {
    /// 5-field cron in Europe/Sofia.
    case cron(String)
    /// Only "Run now".
    case manual

    private enum CodingKeys: String, CodingKey { case kind, cron }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "cron": self = .cron(try c.decode(String.self, forKey: .cron))
        default: self = .manual
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .cron(expr):
            try c.encode("cron", forKey: .kind)
            try c.encode(expr, forKey: .cron)
        case .manual:
            try c.encode("manual", forKey: .kind)
        }
    }
}

/// A conversation job's usage limit setting.
public enum LimitSetting: Codable, Equatable, Hashable, Sendable {
    /// Starts whatever the usage.
    case always
    /// Waits while usage is above these thresholds (percent), or the global ones when nil.
    case wait(fiveHour: Int?, weekly: Int?)

    private enum CodingKeys: String, CodingKey { case mode, fiveHour, weekly }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .mode) {
        case "wait":
            self = .wait(fiveHour: try c.decodeIfPresent(Int.self, forKey: .fiveHour),
                         weekly: try c.decodeIfPresent(Int.self, forKey: .weekly))
        default: self = .always
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always:
            try c.encode("always", forKey: .mode)
        case let .wait(fiveHour, weekly):
            try c.encode("wait", forKey: .mode)
            try c.encodeIfPresent(fiveHour, forKey: .fiveHour)
            try c.encodeIfPresent(weekly, forKey: .weekly)
        }
    }
}

/// Only decides notifications: background scheduled todos send no pushes.
public enum JobPriority: String, Codable, Hashable, Sendable, CaseIterable {
    case urgent, background
}

/// A scheduled conversation on a Mac.
public struct ConversationJobAction: Codable, Equatable, Hashable, Sendable {
    public var projectId: String
    /// nil: the computer of the project's section.
    public var computerId: String?
    public var tool: String
    /// nil: the project folder.
    public var folder: String?
    public var prompt: String
    public var priority: JobPriority
    public var limit: LimitSetting
    /// The tool's model (`haiku`); nil: its default. `tool` may be `auto` (the runner picks).
    public var model: String?

    public init(projectId: String, computerId: String? = nil, tool: String = "claude", folder: String? = nil,
                prompt: String, priority: JobPriority = .background, limit: LimitSetting = .wait(fiveHour: nil, weekly: nil),
                model: String? = nil) {
        self.model = model
        self.projectId = projectId
        self.computerId = computerId
        self.tool = tool
        self.folder = folder
        self.prompt = prompt
        self.priority = priority
        self.limit = limit
    }
}

/// What a job does.
public enum JobAction: Codable, Equatable, Hashable, Sendable {
    case conversation(ConversationJobAction)
    /// Research the project's next idea; the prompt holds optional extra instructions.
    case research(ConversationJobAction)
    case push(title: String, body: String)
    case todo(title: String, projectId: String?, section: String?)
    /// A watcher check; open problems are taken by debugging conversations.
    case watch(WatchJobAction)
    /// A kind this app doesn't know yet (a newer hub). Shown, never sent back.
    case unsupported(kind: String)

    private enum CodingKeys: String, CodingKey { case kind, title, body, projectId, section }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "conversation":
            self = .conversation(try ConversationJobAction(from: decoder))
        case "research":
            self = .research(try ConversationJobAction(from: decoder))
        case "watch":
            self = .watch(try WatchJobAction(from: decoder))
        case "push":
            self = .push(title: try c.decode(String.self, forKey: .title), body: try c.decodeIfPresent(String.self, forKey: .body) ?? "")
        case "todo":
            self = .todo(title: try c.decode(String.self, forKey: .title),
                         projectId: try c.decodeIfPresent(String.self, forKey: .projectId),
                         section: try c.decodeIfPresent(String.self, forKey: .section))
        default:
            self = .unsupported(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .conversation(action):
            try c.encode("conversation", forKey: .kind)
            try action.encode(to: encoder)
        case let .research(action):
            try c.encode("research", forKey: .kind)
            try action.encode(to: encoder)
        case let .watch(action):
            try c.encode("watch", forKey: .kind)
            try action.encode(to: encoder)
        case let .unsupported(kind):
            throw EncodingError.invalidValue(kind, .init(codingPath: encoder.codingPath,
                                                         debugDescription: "This app can't edit \(kind) jobs"))
        case let .push(title, body):
            try c.encode("push", forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encode(body, forKey: .body)
        case let .todo(title, projectId, section):
            try c.encode("todo", forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(projectId, forKey: .projectId)
            try c.encodeIfPresent(section, forKey: .section)
        }
    }
}

/// One run of a job: `due`, `waiting`, `running`, `done`, `failed`, `skipped` or `missed`.
public struct JobRun: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var jobId: String
    public var dueAt: String
    public var state: String
    public var computerId: String?
    public var todoId: String?
    public var waitingReason: String?
    public var result: String?
    public var startedAt: String?
    public var createdAt: String
    public var updatedAt: String
    /// The hint of "shape an idea", or other run-specific text.
    public var note: String?
}

public struct SchedulerJob: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var trigger: JobTrigger
    public var action: JobAction
    public var maxRunsPerDay: Int
    public var createdAt: String
    public var updatedAt: String
    public var lastRun: JobRun?
    /// RFC 3339 UTC; nil for manual or disabled jobs.
    public var nextFireAt: String?
    /// The schedule in plain words, from the hub ("Weekdays at 09:00"); nil on an older hub.
    public var scheduleText: String?
}

/// A run with its job's name (`GET /api/runs`).
public struct RecentRun: Decodable, Equatable, Hashable, Identifiable, Sendable {
    public var run: JobRun
    public var jobName: String
    public var id: String { run.id }

    private enum CodingKeys: String, CodingKey { case jobName }

    public init(from decoder: Decoder) throws {
        run = try JobRun(from: decoder)
        jobName = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .jobName)
    }
}

public enum ScheduleLabel {
    /// The hub's words when it sent them, else the trigger summary.
    public static func text(for job: SchedulerJob) -> String {
        job.scheduleText ?? ScheduledMarker.triggerSummary(job.trigger)
    }
}

public struct CreateJobRequest: Encodable, Sendable {
    public var name: String
    public var enabled: Bool?
    public var trigger: JobTrigger
    public var action: JobAction
    public var maxRunsPerDay: Int?

    public init(name: String, enabled: Bool? = nil, trigger: JobTrigger, action: JobAction, maxRunsPerDay: Int? = nil) {
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.action = action
        self.maxRunsPerDay = maxRunsPerDay
    }
}

/// `PATCH /api/jobs/{id}`; nil fields are left as they are.
public struct UpdateJobRequest: Encodable, Sendable {
    public var name: String?
    public var enabled: Bool?
    public var trigger: JobTrigger?
    public var action: JobAction?
    public var maxRunsPerDay: Int?

    public init(name: String? = nil, enabled: Bool? = nil, trigger: JobTrigger? = nil, action: JobAction? = nil,
                maxRunsPerDay: Int? = nil) {
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.action = action
        self.maxRunsPerDay = maxRunsPerDay
    }
}

/// Global limit-guard settings.
public struct SchedulerSettings: Codable, Equatable, Hashable, Sendable {
    public var fiveHour: Int
    public var weekly: Int
    public var pauseWaiting: Bool

    public init(fiveHour: Int, weekly: Int, pauseWaiting: Bool) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.pauseWaiting = pauseWaiting
    }
}

/// Labels for scheduled todos and jobs.
public enum ScheduledMarker {
    /// "Scheduled · <job name>" on a scheduled todo; "Scheduled" when the job is unknown.
    public static func text(jobName: String?) -> String {
        guard let name = jobName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "Scheduled" }
        return "Scheduled · \(name)"
    }

    public static func triggerSummary(_ trigger: JobTrigger) -> String {
        switch trigger {
        case let .cron(expr): "Cron \(expr)"
        case .manual: "Manual"
        }
    }
}

/// A ready-made job plugin (`/api/job-templates`): a manifest and its prompt, from a computer.
public struct JobTemplate: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var cron: String
    public var tool: String
    public var model: String?
    /// `background` or `urgent`.
    public var priority: String
    /// `wait` or `always`.
    public var limit: String
    /// `choose`, or a project name to preselect.
    public var project: String
    public var prompt: String
    public var computerId: String?
    public var id: String { name }
}
