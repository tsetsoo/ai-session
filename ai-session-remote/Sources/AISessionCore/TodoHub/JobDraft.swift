import Foundation

/// The job form's fields as a value: built from a job, turned back into a request, and
/// compared to tell whether leaving the form would drop changes.
public struct JobDraft: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case conversation = "Conversation", research = "Research ideas", push = "Push", todo = "Todo"
        public var id: String { rawValue }
    }

    public var name = ""
    public var usesCron = true
    public var cron = "0 9 * * *"
    public var kind = Kind.conversation
    public var projectId = ""
    public var computerId = ""
    public var tool = "claude"
    public var prompt = ""
    public var priority = JobPriority.background
    public var waits = true
    public var ownThresholds = false
    public var fiveHour = 60
    public var weekly = 80
    public var title = ""
    public var pushBody = ""
    public var maxRuns = 4
    /// A kind this app can't edit (a newer hub).
    public var unsupportedKind: String?

    public init() {}

    public init(job: SchedulerJob) {
        name = job.name
        maxRuns = job.maxRunsPerDay
        switch job.trigger {
        case let .cron(expr): usesCron = true; cron = expr
        case .manual: usesCron = false
        }
        switch job.action {
        case let .conversation(a), let .research(a):
            if case .research = job.action { kind = .research } else { kind = .conversation }
            projectId = a.projectId
            computerId = a.computerId ?? ""
            tool = a.tool
            prompt = a.prompt
            priority = a.priority
            switch a.limit {
            case .always: waits = false
            case let .wait(five, week):
                waits = true
                ownThresholds = five != nil || week != nil
                fiveHour = five ?? 60
                weekly = week ?? 80
            }
        case let .push(t, b):
            kind = .push; title = t; pushBody = b
        case let .todo(t, p, _):
            kind = .todo; title = t; projectId = p ?? ""
        case let .unsupported(k):
            unsupportedKind = k
        }
    }

    public func isDirty(comparedTo original: JobDraft) -> Bool {
        self != original
    }

    public var canSave: Bool {
        guard unsupportedKind == nil, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if usesCron && cron.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        switch kind {
        case .conversation: return !projectId.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .research: return !projectId.isEmpty
        case .push, .todo: return !title.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    public var trigger: JobTrigger {
        usesCron ? .cron(cron.trimmingCharacters(in: .whitespaces)) : .manual
    }

    private var conversation: ConversationJobAction {
        ConversationJobAction(
            projectId: projectId, computerId: computerId.isEmpty ? nil : computerId, tool: tool, folder: nil,
            prompt: prompt, priority: priority,
            limit: waits ? .wait(fiveHour: ownThresholds ? fiveHour : nil, weekly: ownThresholds ? weekly : nil) : .always
        )
    }

    public var action: JobAction {
        switch kind {
        case .conversation: .conversation(conversation)
        case .research: .research(conversation)
        case .push: .push(title: title, body: pushBody)
        case .todo: .todo(title: title, projectId: projectId.isEmpty ? nil : projectId, section: nil)
        }
    }

    public var createRequest: CreateJobRequest {
        CreateJobRequest(name: name, trigger: trigger, action: action, maxRunsPerDay: maxRuns)
    }

    public var updateRequest: UpdateJobRequest {
        UpdateJobRequest(name: name, trigger: trigger, action: action, maxRunsPerDay: maxRuns)
    }
}

public extension JobDraft {
    /// A new job's form with its project already chosen, so taking it as the "original" leaves
    /// an untouched form clean.
    static func new(defaultProjectID: String?) -> JobDraft {
        var draft = JobDraft()
        draft.projectId = defaultProjectID ?? ""
        return draft
    }
}
