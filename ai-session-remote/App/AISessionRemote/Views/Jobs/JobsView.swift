import AISessionCore
import SwiftUI

/// Scheduler jobs: the usage-limit settings on top, then every job with its trigger, next run
/// and last run, an on/off switch, Run now, its runs, Edit and Delete.
struct JobsView: View {
    let store: TodoHubStore

    @State private var settings: SchedulerSettings?
    @State private var editing: JobEditorTarget?
    @State private var showingRuns: SchedulerJob?
    @State private var deleting: SchedulerJob?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(DS.warning)
            }
            settingsSection
            Section {
                if store.jobs.isEmpty {
                    Text("No jobs yet. A job starts a conversation, sends a push or creates a todo on a schedule.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.jobs) { job in
                    JobRow(job: job, store: store, run: run, toggle: toggle)
                        .contentShape(Rectangle())
                        .onTapGesture { showingRuns = job }
                        .contextMenu {
                            Button("Run Now", systemImage: "play") { run(job) }
                            Button("Edit…", systemImage: "pencil") { editing = .edit(job) }
                            Button("Runs…", systemImage: "list.bullet") { showingRuns = job }
                            Button("Delete…", systemImage: "trash", role: .destructive) { deleting = job }
                        }
                }
            } header: {
                Text("Jobs")
            }
        }
        .navigationTitle("Jobs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = .new
                } label: {
                    Label("New Job", systemImage: "plus")
                }
                .disabled(store.isOffline)
            }
        }
        .task(id: store.revision) { await loadSettings() }
        .sheet(item: $editing) { target in
            NavigationStack { JobEditorView(store: store, target: target) }
        }
        .sheet(item: $showingRuns) { job in
            NavigationStack { JobRunsView(store: store, job: job) }
        }
        .confirmationDialog("Delete this job?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { job in
            Button("Delete \(job.name)", role: .destructive) {
                act { try await store.deleteJob(job) }
            }
        } message: { _ in
            Text("Its run history goes too. Todos it created stay.")
        }
    }

    @ViewBuilder
    private var settingsSection: some View {
        if let settings {
            Section {
                Toggle("Pause waiting jobs", isOn: Binding(
                    get: { settings.pauseWaiting },
                    set: { save(SchedulerSettings(fiveHour: settings.fiveHour, weekly: settings.weekly, pauseWaiting: $0)) }
                ))
                Stepper("5-hour limit: \(settings.fiveHour)%", value: Binding(
                    get: { settings.fiveHour },
                    set: { save(SchedulerSettings(fiveHour: $0, weekly: settings.weekly, pauseWaiting: settings.pauseWaiting)) }
                ), in: 5...100, step: 5)
                Stepper("Weekly limit: \(settings.weekly)%", value: Binding(
                    get: { settings.weekly },
                    set: { save(SchedulerSettings(fiveHour: settings.fiveHour, weekly: $0, pauseWaiting: settings.pauseWaiting)) }
                ), in: 5...100, step: 5)
            } header: {
                Text("Usage limits")
            } footer: {
                Text("Jobs set to wait for headroom don't start while usage is above these. Jobs set to always run ignore them.")
            }
        }
    }

    private func loadSettings() async {
        settings = try? await store.schedulerSettings()
    }

    private func save(_ new: SchedulerSettings) {
        settings = new
        act { try await store.updateSchedulerSettings(new) }
    }

    private func run(_ job: SchedulerJob) {
        act { try await store.runJob(job) }
    }

    private func toggle(_ job: SchedulerJob) {
        act { try await store.updateJob(job, UpdateJobRequest(enabled: !job.enabled)) }
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

/// One job: name, what and when, next run, last run's state, an on/off switch and Run now.
private struct JobRow: View {
    let job: SchedulerJob
    let store: TodoHubStore
    let run: (SchedulerJob) -> Void
    let toggle: (SchedulerJob) -> Void

    var body: some View {
        HStack(spacing: DS.spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let last = job.lastRun {
                    Text(lastRunText(last)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                run(job)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Run \(job.name) now")
            .disabled(store.isOffline)
            Toggle("Enabled", isOn: Binding(get: { job.enabled }, set: { _ in toggle(job) }))
                .labelsHidden()
                .disabled(store.isOffline)
        }
    }

    private var summary: String {
        let what: String = switch job.action {
        case let .conversation(action):
            "\(action.tool.capitalized) in \(store.project(id: action.projectId)?.name ?? "a project")"
        case let .research(action):
            "Research ideas in \(store.project(id: action.projectId)?.name ?? "a project")"
        case .push: "Push"
        case .todo: "Todo"
        case let .unsupported(kind): "\(kind.capitalized) job (needs a newer app)"
        }
        var parts = [what, ScheduledMarker.triggerSummary(job.trigger)]
        if let next = job.nextFireAt.flatMap(HubDates.date(from:)) {
            parts.append("next \(next.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func lastRunText(_ run: JobRun) -> String {
        var text = "Last run: \(run.state)"
        if let reason = run.waitingReason, run.state == "waiting" { text += " (\(reason))" }
        if let result = run.result, run.state == "failed" { text += " (\(result))" }
        return text
    }
}
