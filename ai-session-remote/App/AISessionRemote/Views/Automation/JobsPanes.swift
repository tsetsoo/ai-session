import AISessionCore
import SwiftUI

/// Automation → Jobs, list column: the pinned Usage limits row, then every job with what it
/// does, its schedule and its last run. "+ New" opens the job form in the big pane.
struct JobsList: View {
    let store: TodoHubStore
    /// The pane target; changing it while a form has unsaved changes asks first.
    @Binding var target: JobsPaneTarget?
    let isDirty: Bool

    @State private var pending: JobsPaneTarget??
    @State private var confirmingDiscard = false

    var body: some View {
        List(selection: Binding<String?>(
            get: { target?.listSelection },
            set: { id in go(id == "limits" ? .limits : id.map { .job($0) }) }
        )) {
            Section {
                Label("Usage limits", systemImage: "gauge.with.dots.needle.50percent").tag("limits")
            }
            Section {
                if store.jobs.isEmpty {
                    Text("No jobs yet. A job starts a conversation, researches ideas, sends a push or creates a todo on a schedule.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.jobs) { job in
                    JobListRow(job: job, store: store).tag(job.id)
                }
            } header: {
                Text("Jobs")
            }
        }
        .navigationTitle("Jobs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Job") { go(.new) }
                    if !store.jobTemplates.isEmpty {
                        Section("From a template") {
                            ForEach(store.jobTemplates) { t in
                                Button(t.title.isEmpty ? t.name : t.title) { go(.template(t.name)) }
                            }
                        }
                    }
                } label: {
                    Label("New Job", systemImage: "plus")
                } primaryAction: {
                    go(.new)
                }
                .disabled(store.isOffline)
            }
        }
        .task(id: store.revision) { await store.loadJobTemplates() }
        .confirmationDialog("Discard the unsaved job?", isPresented: $confirmingDiscard) {
            Button("Discard Changes", role: .destructive) {
                if let pending { target = pending }
                pending = nil
            }
            Button("Keep Editing", role: .cancel) { pending = nil }
        }
    }

    private func go(_ next: JobsPaneTarget?) {
        guard next != target else { return }
        if isDirty {
            pending = .some(next)
            confirmingDiscard = true
        } else {
            target = next
        }
    }
}

private struct JobListRow: View {
    let job: SchedulerJob
    let store: TodoHubStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.name).lineLimit(1)
                if !job.enabled {
                    Text("Off").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(JobText.summary(job, store: store)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                Text(ScheduleLabel.text(for: job)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                if let run = job.lastRun {
                    RunStateChip(state: run.state)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Words for a job's action, shared by the list, the detail pane and the phone.
@MainActor
enum JobText {
    static func summary(_ job: SchedulerJob, store: TodoHubStore) -> String {
        switch job.action {
        case let .conversation(a):
            "\(a.tool.capitalized) · \(store.project(id: a.projectId)?.name ?? "a project")"
        case let .research(a):
            "Research ideas · \(store.project(id: a.projectId)?.name ?? "a project") · \(a.tool.capitalized)"
        case .push: "Push"
        case let .todo(_, projectId, _):
            "Todo" + (projectId.flatMap { store.project(id: $0)?.name }.map { " · \($0)" } ?? "")
        case let .watch(w):
            "Watch · \(w.watcher) · \(store.project(id: w.projectId)?.name ?? "a project")"
        case let .unsupported(kind): "\(kind.capitalized) job (needs a newer app)"
        }
    }

    static func does(_ job: SchedulerJob, store: TodoHubStore) -> String {
        switch job.action {
        case let .conversation(a), let .research(a):
            let what = if case .research = job.action { "Researches the next idea" } else { "Starts a conversation" }
            let project = store.project(id: a.projectId)
            let computer = a.computerId.flatMap { id in store.computers.first { $0.id == id }?.name }
                ?? project?.computer.name ?? "the project's computer"
            let limit = switch a.limit {
            case .always: "Always runs."
            case let .wait(five, week):
                "Waits for headroom" + (five != nil || week != nil
                    ? " (5h \(five.map(String.init) ?? "default")%, weekly \(week.map(String.init) ?? "default")%)." : ".")
            }
            let pushes = a.priority == .urgent ? "Sends pushes." : "No pushes."
            return "\(what) in \(project?.name ?? "a project") with \(a.tool.capitalized) on \(computer), in its own worktree. \(limit) \(pushes)"
        case let .push(title, body): return "Sends a push: “\(title)”" + (body.isEmpty ? "" : " — \(body)")
        case let .todo(title, _, _): return "Creates the todo “\(title)”."
        case let .watch(w):
            let computer = store.computers.first { $0.id == w.computerId }?.name ?? "its computer"
            let project = store.project(id: w.projectId)?.name ?? "a project"
            let debug = w.debugTool.map { "Open problems are fixed by \($0.capitalized) conversations in \(project), at most 2 at once." }
                ?? "Push only: no conversations."
            return "Runs the \(w.watcher) watcher on \(computer). New problems push. \(debug)"
        case let .unsupported(kind): return "A \(kind) job. Update the app to see and edit it."
        }
    }
}

/// Automation → Jobs, big pane: what the job does, when, and its runs.
struct JobDetailPane: View {
    let job: SchedulerJob
    let store: TodoHubStore
    let onEdit: () -> Void
    let onDeleted: () -> Void
    let onOpenTodo: (String) -> Void

    @State private var runs: [JobRun]?
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("On", isOn: Binding(get: { job.enabled }, set: { on in
                    act { try await store.updateJob(job, UpdateJobRequest(enabled: on)) }
                }))
                .disabled(store.isOffline)
                HStack {
                    Button("Run Now", systemImage: "play.fill") { act { try await store.runJob(job) } }
                        .buttonStyle(.borderedProminent)
                    Button("Edit", systemImage: "pencil", action: onEdit)
                        .disabled(isUnsupported)
                    Spacer()
                    Menu {
                        Button("Delete Job…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .disabled(store.isOffline)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
                }
            } header: {
                Text(job.name).font(.title2.bold()).foregroundStyle(.primary).textCase(nil)
            }
            Section("Schedule") {
                LabeledContent("When", value: ScheduleLabel.text(for: job))
                if case let .cron(expr) = job.trigger {
                    LabeledContent("Cron", value: expr).font(.body.monospaced())
                }
                if let next = job.nextFireAt.flatMap(HubDates.date(from:)) {
                    LabeledContent("Next run", value: next.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("At most", value: "\(job.maxRunsPerDay) runs a day")
            }
            Section("Does") {
                Text(JobText.does(job, store: store))
            }
            Section("Runs") {
                if let runs {
                    if runs.isEmpty { Text("No runs yet.").foregroundStyle(.secondary) }
                    ForEach(runs) { run in
                        RunRow(run: run, store: store, onOpenTodo: onOpenTodo)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(job.name)
        .task(id: "\(job.id)|\(store.revision)|\(job.lastRun?.id ?? "")|\(job.lastRun?.state ?? "")") {
            runs = try? await store.jobRuns(job)
        }
        .confirmationDialog("Delete \(job.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                act {
                    try await store.deleteJob(job)
                    onDeleted()
                }
            }
        } message: {
            Text("Its run history goes too. Todos it created stay.")
        }
    }

    private var isUnsupported: Bool {
        if case .unsupported = job.action { return true }
        return false
    }

    private func act(_ body: @escaping () async throws -> Void) {
        Task {
            do {
                try await body()
                errorMessage = nil
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
        }
    }
}

/// One run: state, when, why, and its todo.
struct RunRow: View {
    let run: JobRun
    let store: TodoHubStore
    var jobName: String?
    let onOpenTodo: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                RunStateChip(state: run.state)
                if let jobName { Text(jobName).lineLimit(1) }
                Spacer()
                Text(HubDates.date(from: run.dueAt)?.formatted(date: .abbreviated, time: .shortened) ?? run.dueAt)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let detail = run.waitingReason ?? run.result {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let todoId = run.todoId, let todo = store.todos.first(where: { $0.id == todoId }) {
                Button {
                    onOpenTodo(todoId)
                } label: {
                    Label(todo.title, systemImage: "arrow.up.forward.app").font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Automation → Jobs, big pane: the job form (new or edit), on a draft kept in the app model.
struct JobFormPane: View {
    let store: TodoHubStore
    /// The job being edited; nil for a new one.
    let job: SchedulerJob?
    @Binding var draft: JobDraft
    let onDone: (_ savedJobID: String?) -> Void

    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let kind = draft.unsupportedKind {
                Label("This is a \(kind) job. Update the app to edit it.", systemImage: "info.circle")
            }
            Section("Job") {
                TextField("Name", text: $draft.name)
                Picker("Does", selection: $draft.kind) {
                    ForEach(JobDraft.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .task(id: "\(draft.kind.rawValue)|\(draft.computerId)") { if draft.kind == .watch { await store.loadWatchers(computerId: draft.computerId) } }
                .onChange(of: draft.kind) { old, new in
                    // A new watch job checks every 10 minutes unless the cron was changed.
                    if new == .watch, job == nil, draft.cron == JobDraft().cron { draft.cron = JobDraft.watchCron }
                    if old == .watch, job == nil, draft.cron == JobDraft.watchCron { draft.cron = JobDraft().cron }
                }
            }
            Section {
                Toggle("On a schedule", isOn: $draft.usesCron)
                if draft.usesCron {
                    TextField("Cron (minute hour day month weekday)", text: $draft.cron)
                        .font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                if let saved = savedScheduleText {
                    Label(saved, systemImage: "calendar").font(.callout).foregroundStyle(.secondary)
                }
                if draft.kind != .watch {
                    Stepper("At most \(draft.maxRuns) runs a day", value: $draft.maxRuns, in: 1...96)
                }
            } header: {
                Text("When")
            } footer: {
                Text(draft.usesCron ? "Sofia time. Example: 0 9 * * 1-5 is weekdays at 09:00." : "Runs only when you press Run Now.")
            }
            switch draft.kind {
            case .conversation, .research:
                Section(draft.kind == .research ? "Research" : "Conversation") {
                    Picker("Project", selection: $draft.projectId) {
                        if draft.projectId.isEmpty { Text("Choose…").tag("") }
                        ForEach(store.projects, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("Computer", selection: $draft.computerId) {
                        Text("Project's computer").tag("")
                        ForEach(store.computers, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("Tool", selection: $draft.tool) {
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                    }
                    VStack(alignment: .leading) {
                        Text(draft.kind == .research ? "Extra instructions (optional)" : "Prompt")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft.prompt).frame(minHeight: 140).font(.body)
                    }
                }
                Section("Usage limits and pushes") {
                    Picker("Usage limits", selection: $draft.waits) {
                        Text("Wait for headroom").tag(true)
                        Text("Always run").tag(false)
                    }
                    if draft.waits {
                        Toggle("Own thresholds", isOn: $draft.ownThresholds)
                        if draft.ownThresholds {
                            Stepper("5-hour: \(draft.fiveHour)%", value: $draft.fiveHour, in: 5...100, step: 5)
                            Stepper("Weekly: \(draft.weekly)%", value: $draft.weekly, in: 5...100, step: 5)
                        }
                    }
                    Picker("Pushes", selection: $draft.priority) {
                        Text("None (background)").tag(JobPriority.background)
                        Text("Yes (urgent)").tag(JobPriority.urgent)
                    }
                }
            case .push:
                Section("Push") {
                    TextField("Title", text: $draft.title)
                    TextField("Body", text: $draft.pushBody)
                }
            case .watch:
                Section {
                    Picker("Computer", selection: $draft.computerId) {
                        if draft.computerId.isEmpty { Text("Choose…").tag("") }
                        ForEach(store.computers, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    let installed = store.watchersByComputer[draft.computerId] ?? []
                    if installed.isEmpty {
                        TextField("Watcher", text: $draft.watcher)
                            .font(.body.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    } else {
                        Picker("Watcher", selection: $draft.watcher) {
                            if !installed.contains(where: { $0.name == draft.watcher }) { Text(draft.watcher.isEmpty ? "Choose…" : draft.watcher).tag(draft.watcher) }
                            ForEach(installed) { Text($0.title.isEmpty ? $0.name : $0.title).tag($0.name) }
                        }
                    }
                    if let info = installed.first(where: { $0.name == draft.watcher }) {
                        if !info.description.isEmpty { Text(info.description).font(.callout).foregroundStyle(.secondary) }
                        if info.missingSettings.isEmpty {
                            Label("Its settings are set on that computer.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Label("Missing in ~/.ai-remote/watchers/env: " + info.missingSettings.map(\.key).joined(separator: ", "),
                                  systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(DS.warning)
                        }
                    }
                    Picker("Project", selection: $draft.projectId) {
                        if draft.projectId.isEmpty { Text("Choose…").tag("") }
                        ForEach(store.projects, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("Fix with", selection: $draft.debugTool) {
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                        Text("Nobody (push only)").tag("")
                    }
                    if !draft.debugTool.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Extra instructions (optional)").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $draft.prompt).frame(minHeight: 100).font(.body)
                        }
                    }
                } header: {
                    Text("Watch")
                } footer: {
                    Text("The watcher is a file in ~/.ai-remote/watchers on that computer; its secrets stay in ~/.ai-remote/watchers/env there.")
                }
            case .todo:
                Section("Todo") {
                    TextField("Todo title", text: $draft.title)
                    Picker("Project", selection: $draft.projectId) {
                        Text("None").tag("")
                        ForEach(store.projects, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
            }
            Section {
                HStack {
                    Button(job == nil ? "Create Job" : "Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || !draft.canSave || store.isOffline)
                    Button("Cancel") { onDone(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(job == nil ? "New Job" : "Edit \(job?.name ?? "")")

    }

    /// The saved job's schedule in words (and next run) while the cron field still holds it.
    private var savedScheduleText: String? {
        guard let job, case let .cron(expr) = job.trigger, draft.usesCron,
              expr == draft.cron.trimmingCharacters(in: .whitespaces) else { return nil }
        let next = job.nextFireAt.flatMap(HubDates.date(from:)).map { " · next \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return ScheduleLabel.text(for: job) + next
    }

    private func save() {
        saving = true
        Task {
            do {
                if let job {
                    try await store.updateJob(job, draft.updateRequest)
                    onDone(job.id)
                } else {
                    let created = try await store.createJobReturningID(draft.createRequest)
                    onDone(created)
                }
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
            saving = false
        }
    }
}

/// Automation → Jobs → Usage limits, big pane. Saved as they change.
struct UsageLimitsPane: View {
    let store: TodoHubStore

    @State private var settings: SchedulerSettings?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let settings {
                Section {
                    Toggle("Pause waiting jobs", isOn: Binding(get: { settings.pauseWaiting }, set: { save(pause: $0) }))
                    Stepper("5-hour limit: \(settings.fiveHour)%", value: Binding(get: { settings.fiveHour }, set: { save(five: $0) }),
                            in: 5...100, step: 5)
                    Stepper("Weekly limit: \(settings.weekly)%", value: Binding(get: { settings.weekly }, set: { save(weekly: $0) }),
                            in: 5...100, step: 5)
                } footer: {
                    Text("Jobs set to wait for headroom don't start while usage is above these. Jobs set to always run ignore them. A job can also have its own thresholds.")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Usage limits")
        .disabled(store.isOffline)
        .task { settings = try? await store.schedulerSettings() }
    }

    private func save(pause: Bool? = nil, five: Int? = nil, weekly: Int? = nil) {
        guard var new = settings else { return }
        if let pause { new.pauseWaiting = pause }
        if let five { new.fiveHour = five }
        if let weekly { new.weekly = weekly }
        settings = new
        Task {
            do {
                try await store.updateSchedulerSettings(new)
                errorMessage = nil
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
        }
    }
}
