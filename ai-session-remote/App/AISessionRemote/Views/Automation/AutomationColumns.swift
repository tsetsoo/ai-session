import AISessionCore
import SwiftUI

/// Automation's sidebar: Jobs, Ideas, Watchers, Activity.
struct AutomationSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding<AutomationItem?>(get: { model.automationItem }, set: { if let item = $0 { model.automationItem = item } })) {
            ForEach(AutomationItem.allCases) { item in
                Label(item.title, systemImage: item.systemImage)
                    .badge(item == .ideas ? pendingIdeas : item == .watchers ? model.store.openWatchIssueCount : 0)
                    .tag(item)
            }
        }
        .navigationTitle("Automation")
    }

    private var pendingIdeas: Int { model.store.pendingIdeaCount }
}

/// Automation's list column for the chosen sidebar item.
struct AutomationListColumn: View {
    @Environment(AppModel.self) private var model
    let onOpenTodo: (String) -> Void

    var body: some View {
        @Bindable var model = model
        switch model.automationItem {
        case .jobs:
            JobsList(store: model.store, target: Binding(get: { model.automationJobs }, set: { setJobs($0) }),
                     isDirty: model.jobDraftIsDirty)
        case .ideas:
            IdeasList(store: model.store, target: $model.automationIdeas)
        case .watchers:
            WatchersList(store: model.store, selection: $model.automationWatchIssue, onOpenTodo: onOpenTodo)
        case .activity:
            ActivityList(store: model.store, selection: $model.automationRunID, onOpenTodo: onOpenTodo)
        }
    }

    /// A new target: a form gets a fresh draft; leaving a form drops its (confirmed) draft.
    private func setJobs(_ target: JobsPaneTarget?) {
        switch target {
        case .new:
            // The default project goes in before the original is taken, so an untouched
            // form isn't "unsaved".
            let fresh = JobDraft.new(defaultProjectID: model.store.projects.first?.id)
            model.jobDraft = fresh
            model.jobDraftOriginal = fresh
        case let .template(name):
            guard let template = model.store.jobTemplates.first(where: { $0.name == name }) else { return }
            let fresh = JobDraft(template: template, projects: model.store.projects.map { (id: $0.id, name: $0.name) })
            model.jobDraft = fresh
            model.jobDraftOriginal = fresh
        case let .edit(id):
            if let job = model.store.jobs.first(where: { $0.id == id }) {
                model.jobDraft = JobDraft(job: job)
                model.jobDraftOriginal = JobDraft(job: job)
            }
        default:
            model.jobDraft = nil
            model.jobDraftOriginal = nil
        }
        model.automationJobs = target
    }
}

/// Automation's big pane: the selected job, idea or run, or a form.
struct AutomationDetailColumn: View {
    @Environment(AppModel.self) private var model
    /// Opens a todo in Sessions mode.
    let onOpenTodo: (String) -> Void

    var body: some View {
        Group {
            switch model.automationItem {
            case .jobs: jobsPane
            case .ideas: IdeasDetail(store: model.store, target: Binding(get: { model.automationIdeas }, set: { model.automationIdeas = $0 }),
                                     onOpenTodo: onOpenTodo)
            case .watchers: WatchIssueDetail(store: model.store, issueID: model.automationWatchIssue, onOpenTodo: onOpenTodo)
            case .activity: ActivityDetail(store: model.store, runID: model.automationRunID, onOpenJob: openJob, onOpenTodo: onOpenTodo)
            }
        }
    }

    @ViewBuilder
    private var jobsPane: some View {
        let store = model.store
        switch model.automationJobs {
        case .limits:
            UsageLimitsPane(store: store, onOpenTodo: onOpenTodo, onOpenJob: openJob)
        case let .job(id):
            if let job = store.jobs.first(where: { $0.id == id }) {
                JobDetailPane(job: job, store: store, onEdit: { edit(job) }, onDeleted: { model.automationJobs = nil },
                              onOpenTodo: onOpenTodo)
                    .id(job.id)
            } else {
                AutomationEmpty(text: "This job is gone.")
            }
        case .new, .edit, .template:
            if model.jobDraft != nil {
                JobFormPane(store: store, job: editedJob, draft: Binding(get: { model.jobDraft ?? JobDraft() }, set: { model.jobDraft = $0 })) { saved in
                    model.jobDraft = nil
                    model.jobDraftOriginal = nil
                    model.automationJobs = saved.map { .job($0) } ?? editedJob.map { .job($0.id) }
                }
            }
        case nil:
            AutomationEmpty(text: store.jobs.isEmpty ? "Press + to make the first job." : "Choose a job to see what it does and its runs.")
        }
    }

    private var editedJob: SchedulerJob? {
        if case let .edit(id) = model.automationJobs { return model.store.jobs.first { $0.id == id } }
        return nil
    }

    private func edit(_ job: SchedulerJob) {
        model.jobDraft = JobDraft(job: job)
        model.jobDraftOriginal = JobDraft(job: job)
        model.automationJobs = .edit(job.id)
    }

    /// Activity's "Open Job". With an unsaved job form, that form is shown instead (nothing
    /// is dropped); the user can leave it from the Jobs list, which asks first.
    private func openJob(_ id: String) {
        model.automationItem = .jobs
        if !model.jobDraftIsDirty {
            model.automationJobs = .job(id)
        }
    }
}

struct AutomationEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
