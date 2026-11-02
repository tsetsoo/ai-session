import AISessionCore
import SwiftUI

enum JobEditorTarget: Identifiable {
    case new
    case edit(SchedulerJob)

    var id: String {
        switch self {
        case .new: "new"
        case let .edit(job): job.id
        }
    }
}

/// Create or edit a job: name, when (cron or manual), what (a conversation, a push or a todo)
/// and, for conversations, where it runs and its usage limit setting.
struct JobEditorView: View {
    let store: TodoHubStore
    let target: JobEditorTarget

    @Environment(\.dismiss) private var dismiss

    private enum Kind: String, CaseIterable, Identifiable {
        case conversation = "Conversation", push = "Push", todo = "Todo"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var usesCron = true
    @State private var cron = "0 9 * * *"
    @State private var kind = Kind.conversation
    @State private var projectId = ""
    @State private var computerId = ""
    @State private var tool = "claude"
    @State private var prompt = ""
    @State private var priority = JobPriority.background
    @State private var waits = true
    @State private var ownThresholds = false
    @State private var fiveHour = 60
    @State private var weekly = 80
    @State private var title = ""
    @State private var pushBody = ""
    @State private var maxRuns = 4
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                Toggle("On a schedule", isOn: $usesCron)
                if usesCron {
                    TextField("Cron (minute hour day month weekday)", text: $cron)
                        .font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                Stepper("At most \(maxRuns) runs a day", value: $maxRuns, in: 1...96)
            } footer: {
                Text(usesCron ? "Sofia time. Example: 0 8 * * 1-5 is weekdays at 08:00." : "Runs only when you press Run now.")
            }
            Section("Does") {
                Picker("Action", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                switch kind {
                case .conversation: conversationFields
                case .push:
                    TextField("Title", text: $title)
                    TextField("Body", text: $pushBody)
                case .todo:
                    TextField("Todo title", text: $title)
                    projectPicker(optional: true)
                }
            }
            if kind == .conversation {
                Section {
                    Picker("Usage limits", selection: $waits) {
                        Text("Wait for headroom").tag(true)
                        Text("Always run").tag(false)
                    }
                    if waits {
                        Toggle("Own thresholds", isOn: $ownThresholds)
                        if ownThresholds {
                            Stepper("5-hour: \(fiveHour)%", value: $fiveHour, in: 5...100, step: 5)
                            Stepper("Weekly: \(weekly)%", value: $weekly, in: 5...100, step: 5)
                        }
                    }
                    Picker("Priority", selection: $priority) {
                        Text("Background (no pushes)").tag(JobPriority.background)
                        Text("Urgent (pushes)").tag(JobPriority.urgent)
                    }
                } header: {
                    Text("Limits and pushes")
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
            }
        }
        .navigationTitle(isNew ? "New Job" : "Edit Job")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(saving || !canSave)
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var conversationFields: some View {
        projectPicker(optional: false)
        Picker("Computer", selection: $computerId) {
            Text("Project's computer").tag("")
            ForEach(store.computers, id: \.id) { Text($0.name).tag($0.id) }
        }
        Picker("Tool", selection: $tool) {
            Text("Claude").tag("claude")
            Text("Codex").tag("codex")
        }
        VStack(alignment: .leading) {
            Text("Prompt").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $prompt).frame(minHeight: 120)
        }
    }

    private func projectPicker(optional: Bool) -> some View {
        Picker("Project", selection: $projectId) {
            if optional { Text("None").tag("") }
            ForEach(store.projects, id: \.id) { Text($0.name).tag($0.id) }
        }
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if usesCron && cron.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        switch kind {
        case .conversation: return !projectId.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .push, .todo: return !title.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var trigger: JobTrigger {
        usesCron ? .cron(cron.trimmingCharacters(in: .whitespaces)) : .manual
    }

    private var action: JobAction {
        switch kind {
        case .conversation:
            .conversation(ConversationJobAction(
                projectId: projectId, computerId: computerId.isEmpty ? nil : computerId, tool: tool, folder: nil,
                prompt: prompt, priority: priority,
                limit: waits ? .wait(fiveHour: ownThresholds ? fiveHour : nil, weekly: ownThresholds ? weekly : nil) : .always
            ))
        case .push: .push(title: title, body: pushBody)
        case .todo: .todo(title: title, projectId: projectId.isEmpty ? nil : projectId, section: nil)
        }
    }

    private func load() {
        guard case let .edit(job) = target else {
            projectId = store.projects.first?.id ?? ""
            return
        }
        name = job.name
        maxRuns = job.maxRunsPerDay
        switch job.trigger {
        case let .cron(expr): usesCron = true; cron = expr
        case .manual: usesCron = false
        }
        switch job.action {
        case let .conversation(a):
            kind = .conversation
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
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                switch target {
                case .new:
                    try await store.createJob(CreateJobRequest(name: name, trigger: trigger, action: action, maxRunsPerDay: maxRuns))
                case let .edit(job):
                    try await store.updateJob(job, UpdateJobRequest(name: name, trigger: trigger, action: action, maxRunsPerDay: maxRuns))
                }
                dismiss()
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
            saving = false
        }
    }
}
