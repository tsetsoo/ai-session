import AISessionCore
import SwiftUI

/// Automation → Ideas, list column: ideas of every project, grouped by project, with filter
/// chips. Ideas waiting for OK can be approved or rejected right in the list.
struct IdeasList: View {
    let store: TodoHubStore
    @Binding var target: IdeasPaneTarget?

    @Environment(AppModel.self) private var model
    @State private var filter = IdeaFilter.all
    @State private var errorMessage: String?

    var body: some View {
        List(selection: Binding<String?>(
            get: { if case let .idea(id) = target { id } else { nil } },
            set: { id in target = id.map { .idea($0) } }
        )) {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(IdeaFilter.allCases, id: \.self) { f in
                        Text(f == .waiting && store.pendingIdeaCount > 0 ? "\(f.label) (\(store.pendingIdeaCount))" : f.label).tag(f)
                    }
                }
                if let project = filteredProject {
                    HStack {
                        Text("Only \(project.name)").font(.caption)
                        Spacer()
                        Button("Show all projects") { model.automationIdeasProject = nil }.font(.caption)
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(DS.warning)
                }
            }
            let shown = store.allIdeas.filter { filter.matches($0) && (model.automationIdeasProject == nil || $0.projectId == model.automationIdeasProject) }
            if shown.isEmpty {
                Text(store.allIdeas.isEmpty ? "No ideas yet. Add one, or shape one with an agent." : "Nothing here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(IdeaGrouping.byProject(shown, projects: store.projects), id: \.ideas.first?.projectId) { group in
                Section(group.project?.name ?? "Other") {
                    ForEach(group.ideas) { idea in
                        IdeaListRow(idea: idea, store: store, act: act).tag(idea.id)
                    }
                }
            }
        }
        .navigationTitle("Ideas")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { target = .shape } label: { Label("Shape with an Agent", systemImage: "bubble.left.and.text.bubble.right") }
                Button { target = .new } label: { Label("New Idea", systemImage: "plus") }
            }
        }
        .disabled(store.isOffline && store.allIdeas.isEmpty)
        .task(id: store.revision) { await store.loadAllIdeas() }
    }

    private var filteredProject: Project? {
        model.automationIdeasProject.flatMap { store.project(id: $0) }
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

private struct IdeaListRow: View {
    let idea: Idea
    let store: TodoHubStore
    let act: (@escaping () async throws -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: idea.starred ? "star.fill" : "lightbulb")
                    .foregroundStyle(idea.starred ? .yellow : .secondary)
                Text(idea.title).lineLimit(2)
            }
            HStack(spacing: 6) {
                if idea.pending {
                    Text("Waiting for OK").font(.caption2).foregroundStyle(.orange)
                    Spacer()
                    Button("Approve") { act { try await store.updateIdea(idea, UpdateIdeaRequest(pending: false)) } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Reject", role: .destructive) { act { try await store.deleteIdea(idea) } }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Text(idea.status.label).font(.caption2).foregroundStyle(.secondary)
                    if idea.findings != nil { Text("· findings").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Automation → Ideas, big pane.
struct IdeasDetail: View {
    let store: TodoHubStore
    @Binding var target: IdeasPaneTarget?
    let onOpenTodo: (String) -> Void

    var body: some View {
        switch target {
        case let .idea(id):
            if let idea = store.allIdeas.first(where: { $0.id == id }) {
                IdeaDetailPane(idea: idea, store: store, onOpenTodo: onOpenTodo, onDeleted: { target = nil })
                    .id(idea.id + idea.updatedAt)
            } else {
                AutomationEmpty(text: "This idea is gone.")
            }
        case .new:
            NewIdeaPane(store: store) { target = $0.map { .idea($0) } }
        case .shape:
            ShapeIdeaPane(store: store) { target = nil }
        case nil:
            AutomationEmpty(text: "Choose an idea to read its notes and findings.")
        }
    }
}

/// One idea: notes, findings as a readable page, and what to do with it.
struct IdeaDetailPane: View {
    let idea: Idea
    let store: TodoHubStore
    let onOpenTodo: (String) -> Void
    let onDeleted: () -> Void

    @State private var title = ""
    @State private var notes = ""
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                if idea.pending {
                    HStack {
                        Label("An agent proposed this idea.", systemImage: "hand.raised")
                        Spacer()
                        Button("Approve") { act { try await store.updateIdea(idea, UpdateIdeaRequest(pending: false)) } }
                            .buttonStyle(.borderedProminent)
                        Button("Reject", role: .destructive) {
                            act {
                                try await store.deleteIdea(idea)
                                onDeleted()
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Text(idea.status.label).font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    if let project = store.project(id: idea.projectId) { Text(project.name).foregroundStyle(.secondary) }
                    Spacer()
                    Button {
                        act { try await store.updateIdea(idea, UpdateIdeaRequest(starred: !idea.starred)) }
                    } label: {
                        Label(idea.starred ? "Starred" : "Star", systemImage: idea.starred ? "star.fill" : "star")
                    }
                    Button("Research Now", systemImage: "magnifyingglass") { act { try await store.researchIdea(idea) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(idea.status != .new || idea.pending)
                        .help(idea.status == .new ? "Starts a research conversation on this idea now" : "Only new ideas can be researched")
                    Menu {
                        Button("Turn into Todo", systemImage: "checklist") {
                            act { onOpenTodo(try await store.ideaToTodo(idea)) }
                        }
                        if idea.status != .dropped {
                            Button("Drop", systemImage: "xmark.circle") {
                                act { try await store.updateIdea(idea, UpdateIdeaRequest(status: .dropped)) }
                            }
                        } else {
                            Button("Bring Back", systemImage: "arrow.uturn.backward") {
                                act { try await store.updateIdea(idea, UpdateIdeaRequest(status: .new)) }
                            }
                        }
                        Button("Delete…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
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
            }
            Section("Idea") {
                TextField("Title", text: $title)
                TextEditor(text: $notes).frame(minHeight: 70)
                if let request = IdeaEdit.request(original: idea, title: title, notes: notes, status: idea.status, starred: idea.starred) {
                    Button("Save Changes") { act { try await store.updateIdea(idea, request) } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let findings = idea.findings, !findings.isEmpty {
                Section("Findings") {
                    Text(Self.markdown(findings)).textSelection(.enabled)
                }
            } else if idea.status == .researching {
                Section("Findings") {
                    Label("Research is running. Findings appear here when it saves them.", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
            }
            if let todoId = idea.todoId, store.todos.contains(where: { $0.id == todoId }) {
                Section {
                    Button("Open Its Todo", systemImage: "arrow.up.forward.app") { onOpenTodo(todoId) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(idea.title)
        .onAppear {
            title = idea.title
            notes = idea.notes
        }
        .confirmationDialog("Delete this idea?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                act {
                    try await store.deleteIdea(idea)
                    onDeleted()
                }
            }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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

/// A new idea, in the big pane.
struct NewIdeaPane: View {
    let store: TodoHubStore
    let onDone: (String?) -> Void

    @Environment(AppModel.self) private var model
    @State private var projectId = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("New idea") {
                Picker("Project", selection: $projectId) {
                    ForEach(store.projects, id: \.id) { Text($0.name).tag($0.id) }
                }
                TextField("Idea", text: $title)
                VStack(alignment: .leading) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $notes).frame(minHeight: 100)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
            }
            Section {
                HStack {
                    Button("Add Idea") {
                        Task {
                            do {
                                try await store.createIdea(CreateIdeaRequest(projectId: projectId, title: title, notes: notes))
                                await store.loadAllIdeas()
                                onDone(store.allIdeas.first { $0.title == title.trimmingCharacters(in: .whitespaces) && $0.projectId == projectId }?.id)
                            } catch {
                                errorMessage = TodoHubStore.message(for: error)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(projectId.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty || store.isOffline)
                    Button("Cancel") { onDone(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Idea")
        .onAppear { projectId = model.automationIdeasProject ?? store.projects.first?.id ?? "" }
    }
}

/// "Shape an idea with an agent", in the big pane.
struct ShapeIdeaPane: View {
    let store: TodoHubStore
    let onDone: () -> Void

    @Environment(AppModel.self) private var model
    @State private var projectId = ""
    @State private var hint = ""
    @State private var started = false
    @State private var sending = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if started {
                Section {
                    Label("Started. In a minute or two it shows up in Ready for review with its first question. The idea it saves waits for your OK here.",
                          systemImage: "checkmark.circle")
                    Button("Done", action: onDone)
                }
            } else {
                Section {
                    Picker("Project", selection: $projectId) {
                        ForEach(store.projects, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    TextField("What's the idea about?", text: $hint, axis: .vertical).lineLimit(2...6)
                } header: {
                    Text("Shape an idea with an agent")
                } footer: {
                    Text("An agent asks you a few questions in a new conversation, then saves the idea.")
                }
                Section {
                    HStack {
                        Button("Start") {
                            sending = true
                            Task {
                                do {
                                    try await store.shapeIdea(projectId: projectId, hint: hint)
                                    started = true
                                } catch {
                                    errorMessage = TodoHubStore.message(for: error)
                                }
                                sending = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sending || projectId.isEmpty || hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isOffline)
                        Button("Cancel", action: onDone)
                    }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shape an Idea")
        .onAppear { projectId = model.automationIdeasProject ?? store.projects.first?.id ?? "" }
    }
}

/// Automation → Activity, list column: the newest runs across jobs.
struct ActivityList: View {
    let store: TodoHubStore
    @Binding var selection: String?
    let onOpenTodo: (String) -> Void

    var body: some View {
        List(selection: $selection) {
            if let runs = store.recentRuns {
                if runs.isEmpty { Text("No runs yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(runs) { recent in
                    RunRow(run: recent.run, store: store, jobName: recent.jobName, onOpenTodo: onOpenTodo).tag(recent.id)
                }
            } else {
                Text("Activity needs a newer hub.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Activity")
        .task(id: store.revision) { await store.loadRecentRuns() }
    }
}

/// Automation → Activity, big pane: one run.
struct ActivityDetail: View {
    let store: TodoHubStore
    let runID: String?
    /// nil where a job can't be opened from here (the phone).
    let onOpenJob: ((String) -> Void)?
    let onOpenTodo: (String) -> Void
    /// What the run's todo used (its conversations and their sub-agents).
    @State private var usage: UsageSummary?

    var body: some View {
        if let recent = store.recentRuns?.first(where: { $0.id == runID }) {
            let run = recent.run
            Form {
                Section {
                    HStack {
                        RunStateChip(state: run.state)
                        Text(recent.jobName).font(.title3.bold())
                    }
                    LabeledContent("Due", value: HubDates.date(from: run.dueAt)?.formatted(date: .abbreviated, time: .shortened) ?? run.dueAt)
                    if let started = run.startedAt {
                        LabeledContent("Started", value: HubDates.date(from: started)?.formatted(date: .abbreviated, time: .shortened) ?? started)
                    }
                    if let computer = run.computerId.flatMap({ id in store.computers.first { $0.id == id }?.name }) {
                        LabeledContent("Computer", value: computer)
                    }
                    if let reason = run.waitingReason { LabeledContent("Waiting because", value: reason) }
                    if let result = run.result { LabeledContent("Result", value: result) }
                }
                if let usage, !usage.isEmpty {
                    Section("Usage") {
                        UsageDetailView(usage: usage, title: "This run")
                    }
                }
                Section {
                    if let onOpenJob {
                        Button("Open Job", systemImage: "clock.arrow.circlepath") { onOpenJob(run.jobId) }
                    }
                    if let todoId = run.todoId {
                        Button("Open Its Todo", systemImage: "arrow.up.forward.app") { onOpenTodo(todoId) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(recent.jobName)
            .task(id: "\(run.id)|\(run.state)") {
                usage = nil
                guard let todoId = run.todoId else { return }
                usage = try? await store.todoUsage(todoId: todoId)
            }
        } else {
            AutomationEmpty(text: "Choose a run to see what happened.")
        }
    }
}
