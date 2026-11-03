import AISessionCore
import SwiftUI

/// The phone's Automation tab: Jobs, Ideas and Activity, each pushing the same panes the Mac
/// shows in its big pane.
struct PhoneAutomationRoot: View {
    let store: TodoHubStore
    let onOpenTodo: (String) -> Void

    var body: some View {
        List {
            NavigationLink { PhoneJobsList(store: store, onOpenTodo: onOpenTodo) } label: {
                Label(AutomationItem.jobs.title, systemImage: AutomationItem.jobs.systemImage)
            }
            NavigationLink { PhoneIdeasList(store: store, onOpenTodo: onOpenTodo) } label: {
                Label(AutomationItem.ideas.title, systemImage: AutomationItem.ideas.systemImage)
                    .badge(store.pendingIdeaCount)
            }
            NavigationLink { PhoneActivityList(store: store, onOpenTodo: onOpenTodo) } label: {
                Label(AutomationItem.activity.title, systemImage: AutomationItem.activity.systemImage)
            }
        }
        .task(id: store.revision) { await store.loadAllIdeas() }
    }
}

private struct PhoneJobsList: View {
    let store: TodoHubStore
    let onOpenTodo: (String) -> Void

    var body: some View {
        List {
            NavigationLink { UsageLimitsPane(store: store) } label: {
                Label("Usage limits", systemImage: "gauge.with.dots.needle.50percent")
            }
            Section("Jobs") {
                if store.jobs.isEmpty {
                    Text("No jobs yet. Press + to make one.").foregroundStyle(.secondary)
                }
                ForEach(store.jobs) { job in
                    NavigationLink { PhoneJobDetail(store: store, jobID: job.id, onOpenTodo: onOpenTodo) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.name)
                            Text(JobText.summary(job, store: store)).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(ScheduleLabel.text(for: job)).font(.caption2).foregroundStyle(.tertiary)
                                if let run = job.lastRun { RunStateChip(state: run.state) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Jobs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { PhoneJobForm(store: store, job: nil) } label: { Label("New Job", systemImage: "plus") }
                    .disabled(store.isOffline)
            }
        }
    }
}

private struct PhoneJobDetail: View {
    let store: TodoHubStore
    let jobID: String
    let onOpenTodo: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editing = false

    var body: some View {
        if let job = store.jobs.first(where: { $0.id == jobID }) {
            JobDetailPane(job: job, store: store, onEdit: { editing = true }, onDeleted: { dismiss() }, onOpenTodo: onOpenTodo)
                .navigationDestination(isPresented: $editing) { PhoneJobForm(store: store, job: job) }
        } else {
            AutomationEmpty(text: "This job is gone.")
        }
    }
}

/// The job form on the phone: its own draft, discarded only after asking.
private struct PhoneJobForm: View {
    let store: TodoHubStore
    let job: SchedulerJob?

    @Environment(\.dismiss) private var dismiss
    @State private var draft = JobDraft()
    @State private var original = JobDraft()
    @State private var loaded = false
    @State private var confirmingDiscard = false

    var body: some View {
        JobFormPane(store: store, job: job, draft: $draft) { saved in
            if saved == nil && draft.isDirty(comparedTo: original) {
                confirmingDiscard = true
            } else {
                dismiss()
            }
        }
        .navigationBarBackButtonHidden(draft.isDirty(comparedTo: original))
        .confirmationDialog("Discard the unsaved job?", isPresented: $confirmingDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = job.map(JobDraft.init(job:)) ?? JobDraft.new(defaultProjectID: store.projects.first?.id)
            original = draft
        }
    }
}

private struct PhoneIdeasList: View {
    let store: TodoHubStore
    let onOpenTodo: (String) -> Void

    @Environment(AppModel.self) private var model
    @State private var filter = IdeaFilter.all

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(IdeaFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if let project = model.automationIdeasProject.flatMap({ store.project(id: $0) }) {
                    Button("Only \(project.name) — show all") { model.automationIdeasProject = nil }.font(.caption)
                }
            }
            let shown = store.allIdeas.filter { filter.matches($0) && (model.automationIdeasProject == nil || $0.projectId == model.automationIdeasProject) }
            ForEach(IdeaGrouping.byProject(shown, projects: store.projects), id: \.ideas.first?.projectId) { group in
                Section(group.project?.name ?? "Other") {
                    ForEach(group.ideas) { idea in
                        NavigationLink {
                            PhoneIdeaDetail(store: store, ideaID: idea.id, onOpenTodo: onOpenTodo)
                        } label: {
                            HStack {
                                Image(systemName: idea.starred ? "star.fill" : "lightbulb").foregroundStyle(idea.starred ? .yellow : .secondary)
                                VStack(alignment: .leading) {
                                    Text(idea.title).lineLimit(2)
                                    Text(idea.pending ? "Waiting for OK" : idea.status.label + (idea.findings != nil ? " · findings" : ""))
                                        .font(.caption).foregroundStyle(idea.pending ? .orange : .secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Ideas")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NavigationLink { PhoneSimplePane { done in ShapeIdeaPane(store: store, onDone: done) } } label: {
                    Label("Shape with an Agent", systemImage: "bubble.left.and.text.bubble.right")
                }
                NavigationLink { PhoneSimplePane { done in NewIdeaPane(store: store) { _ in done() } } } label: {
                    Label("New Idea", systemImage: "plus")
                }
            }
        }
        .task(id: store.revision) { await store.loadAllIdeas() }
    }
}

private struct PhoneIdeaDetail: View {
    let store: TodoHubStore
    let ideaID: String
    let onOpenTodo: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let idea = store.allIdeas.first(where: { $0.id == ideaID }) {
            IdeaDetailPane(idea: idea, store: store, onOpenTodo: onOpenTodo, onDeleted: { dismiss() })
                .id(idea.id + idea.updatedAt)
        } else {
            AutomationEmpty(text: "This idea is gone.")
        }
    }
}

/// A pushed pane that pops itself when done.
private struct PhoneSimplePane<Content: View>: View {
    @ViewBuilder let content: (@escaping () -> Void) -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content { dismiss() }
    }
}

private struct PhoneActivityList: View {
    let store: TodoHubStore
    let onOpenTodo: (String) -> Void

    var body: some View {
        List {
            if let runs = store.recentRuns {
                if runs.isEmpty { Text("No runs yet.").foregroundStyle(.secondary) }
                ForEach(runs) { recent in
                    NavigationLink {
                        ActivityDetail(store: store, runID: recent.id, onOpenJob: nil, onOpenTodo: onOpenTodo)
                    } label: {
                        RunRow(run: recent.run, store: store, jobName: recent.jobName, onOpenTodo: onOpenTodo)
                    }
                }
            } else {
                Text("Activity needs a newer hub.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Activity")
        .task(id: store.revision) { await store.loadRecentRuns() }
    }
}
