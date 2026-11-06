import AISessionCore
import SwiftData
import SwiftUI

/// A computer's health: what needs attention, its agent CLIs (version, who installs them,
/// login), the conversations still running an older version, the status monitor and the
/// helper scripts. It shows the hub's last report at once, then asks the computer itself;
/// when the computer can't be reached the hub's report stays, with its time.
///
/// Installing an update doesn't change what a running conversation uses. A conversation on an
/// older version can be restarted from its row, one at a time and only when the user asks.
struct ComputerHealthView: View {
    let computer: Computer

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]

    @State private var snapshot: ComputerHealthSnapshot?
    @State private var hubError: String?
    @State private var live: HostHealth?
    @State private var liveError: String?
    @State private var isChecking = false
    /// Restart asked for (confirm), then forcing one the computer refused, and those running.
    @State private var confirmRestart: HealthRestart?
    @State private var forceRestart: HealthRestart?
    @State private var restarting: Set<String> = []
    @State private var restartNote: String?

    private var store: TodoHubStore { model.store }
    private var report: HostHealth? { live ?? snapshot?.report }

    var body: some View {
        List {
            Section {
                sourceRow
            }
            if let report {
                problemsSection(report)
                toolsSection(report)
                outdatedSection(report)
                monitorSection(report)
                helpersSection(report)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Health")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await checkLive() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(isChecking || HostLookup.host(for: computer, in: hosts) == nil)
            }
        }
        .confirmationDialog(
            confirmRestart.map { "Restart \($0.title)?" } ?? "",
            isPresented: Binding(get: { confirmRestart != nil }, set: { if !$0 { confirmRestart = nil } }),
            titleVisibility: .visible,
            presenting: confirmRestart
        ) { request in
            Button("Restart") { runRestart(request, force: false) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.detail + " It resumes in the same conversation and folder; text typed but not sent is lost.")
        }
        .confirmationDialog(
            forceRestart.map { "Restart \($0.title) Anyway?" } ?? "",
            isPresented: Binding(get: { forceRestart != nil }, set: { if !$0 { forceRestart = nil } }),
            titleVisibility: .visible,
            presenting: forceRestart
        ) { request in
            Button("Restart", role: .destructive) { runRestart(request, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text((request.refusal ?? "") + " Restarting stops it where it is.")
        }
        .task(id: computer.id) {
            await loadHub()
            await checkLive()
        }
        .refreshable { await checkLive() }
    }

    // MARK: Source

    @ViewBuilder
    private var sourceRow: some View {
        VStack(alignment: .leading, spacing: DS.spacing.xs) {
            if isChecking {
                HStack(spacing: DS.spacing.s) {
                    ProgressView()
                    Text("Checking \(computer.name)…")
                }
            }
            if let live {
                Label {
                    Text("Checked on \(computer.name) ") + relative(live.checkedAt)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } else if let report = snapshot?.report {
                Label {
                    Text("Last report from \(computer.name) ") + relative(snapshot?.reportedDate ?? report.checkedAt)
                } icon: {
                    Image(systemName: "clock")
                }
            } else if !isChecking {
                Label("No report from \(computer.name) yet", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            if let liveError {
                Text(liveError)
                    .font(.caption)
                    .foregroundStyle(DS.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if HostLookup.host(for: computer, in: hosts) == nil {
                Text("This device can't reach \(computer.name) directly, so this is the report it last sent the hub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let hubError, live == nil {
                Text(hubError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DS.spacing.xs)
    }

    private func relative(_ date: Date?) -> Text {
        guard let date else { return Text("(time unknown)") }
        return Text(date, format: .relative(presentation: .named))
    }

    // MARK: Sections

    @ViewBuilder
    private func problemsSection(_ report: HostHealth) -> some View {
        let problems = report.problems
        Section {
            if problems.isEmpty {
                Label("Nothing needs attention", systemImage: "checkmark.seal")
            }
            ForEach(problems, id: \.self) { problem in
                Label {
                    Text(problem.text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DS.warning)
                }
            }
        } header: {
            Text("Needs Attention").textCase(nil)
        }
    }

    @ViewBuilder
    private func toolsSection(_ report: HostHealth) -> some View {
        if !report.orderedTools.isEmpty {
            Section {
                ForEach(report.orderedTools, id: \.name) { entry in
                    toolRow(name: entry.name, tool: entry.tool)
                }
            } header: {
                Text("Agent CLIs").textCase(nil)
            } footer: {
                Text("The version a new conversation starts with, and what installed it.")
            }
        }
    }

    private func toolRow(name: String, tool: HostHealth.Tool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(HostHealth.toolName(name)).font(.headline)
                Spacer()
                Text(tool.installed == true ? (tool.version ?? "version unknown") : "Not installed")
                    .monospacedDigit()
                    .foregroundStyle(tool.installed == true ? .primary : .secondary)
            }
            if tool.installed == true {
                Text(toolDetail(tool))
                    .font(.caption)
                    .foregroundStyle(tool.auth?.loggedIn == false ? DS.warning : .secondary)
                if let daemon = tool.daemon, let version = daemon.version, version != tool.version {
                    Text("Shared Codex server runs \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func toolDetail(_ tool: HostHealth.Tool) -> String {
        var parts: [String] = []
        if let method = HostHealth.methodName(tool.method) { parts.append(method) }
        switch tool.auth?.loggedIn {
        case true?: parts.append(tool.auth?.method.map { "logged in (\($0))" } ?? "logged in")
        case false?: parts.append("not logged in")
        case nil: parts.append("login unknown")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func outdatedSection(_ report: HostHealth) -> some View {
        if let running = report.running {
            let outdated = report.outdatedRunning
            Section {
                if outdated.isEmpty {
                    Text(running.isEmpty ? "No conversations running" : "All \(running.count) running conversations use the installed version")
                        .foregroundStyle(.secondary)
                }
                ForEach(outdated) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(for: entry)).lineLimit(1)
                            Text(versionDetail(entry, installed: report.tools?[entry.tool]?.version))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: DS.spacing.s)
                        if restarting.contains(entry.tmux) {
                            ProgressView().controlSize(.small)
                        } else if let conversation = conversation(for: entry), HostLookup.host(for: computer, in: hosts) != nil {
                            Button("Restart") {
                                confirmRestart = HealthRestart(
                                    conversation: conversation, title: title(for: entry),
                                    detail: versionDetail(entry, installed: report.tools?[entry.tool]?.version) + ".")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if let restartNote {
                    Text(restartNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Running an Older Version").textCase(nil)
            } footer: {
                if !outdated.isEmpty {
                    Text("\(outdated.count) of \(running.count) running conversations. A conversation keeps the version it started with until it's restarted; installing an update doesn't change it. Restart one when it's not working on something.")
                }
            }
        }
    }

    /// The hub's conversation for this tmux session: a todo's. Others can't be restarted here.
    private func conversation(for entry: HostHealth.Running) -> Conversation? {
        store.conversations.values.first { $0.computer.id == computer.id && $0.tmuxName == entry.tmux }
    }

    /// The todo the conversation belongs to, else its tmux session name.
    private func title(for entry: HostHealth.Running) -> String {
        guard let conversation = conversation(for: entry) else { return entry.tmux }
        return store.todos.first(where: { $0.id == conversation.todoId })?.title ?? entry.tmux
    }

    /// Restarts it on the computer and starts it again there (no terminal attaches here).
    /// Working or waiting is refused first and asked about; background tasks are not forced.
    private func runRestart(_ request: HealthRestart, force: Bool) {
        let tmux = request.conversation.tmuxName
        restarting.insert(tmux)
        Task {
            defer { restarting.remove(tmux) }
            do {
                let config = try HostLookup.config(for: computer, in: hosts)
                let result = try await RemoteRestart.restart(request.conversation, config: config, force: force, reopen: true)
                if result.isRefused {
                    if result.canForce {
                        forceRestart = HealthRestart(conversation: request.conversation, title: request.title,
                                                     detail: request.detail, refusal: result.message)
                    } else {
                        restartNote = "\(request.title): \(result.message ?? "Can't restart it now.")"
                    }
                    return
                }
                restartNote = result.result == "failed"
                    ? "\(request.title): \(result.message ?? "The restart failed.")"
                    : "\(request.title): \(RemoteRestart.summary(result))"
            } catch {
                restartNote = "\(request.title): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                return
            }
            await checkLive()
        }
    }

    private func versionDetail(_ entry: HostHealth.Running, installed: String?) -> String {
        let tool = HostHealth.toolName(entry.tool)
        var text = "\(tool) \(entry.version ?? "unknown")"
        if let backend = entry.backendVersion, backend != entry.version {
            text += ", its server \(backend)"
        }
        if let installed { text += " · installed \(installed)" }
        return text
    }

    @ViewBuilder
    private func monitorSection(_ report: HostHealth) -> some View {
        Section {
            LabeledContent("Codex status monitor", value: state(report.serviceRunning, yes: "Running", no: "Not running"))
            LabeledContent("Claude status monitor", value: state(report.claudeService?.fresh, yes: "Running", no: "Stopped"))
            if let hooks = report.hooks {
                let trusted = hooks.filter { $0.enabled == true && $0.trustStatus == "trusted" }.count
                LabeledContent("Codex hooks", value: "\(trusted) of \(hooks.count) trusted")
            }
            if let deliveries = report.deliveries {
                LabeledContent("Status updates", value: deliveryText(deliveries))
            }
        } header: {
            Text("Status Monitor").textCase(nil)
        } footer: {
            if let unlinked = report.deliveries?.unlinked, unlinked > 0 {
                Text("Updates for conversations not linked to a todo are kept for a day, then dropped. They aren't a problem.")
            }
        }
    }

    private func state(_ value: Bool?, yes: String, no: String) -> String {
        switch value {
        case true?: yes
        case false?: no
        case nil: "Unknown"
        }
    }

    private func deliveryText(_ deliveries: HostHealth.Deliveries) -> String {
        var parts: [String] = []
        if let failing = deliveries.failing, failing > 0 { parts.append("\(failing) failing") }
        if let flight = deliveries.inFlight, flight > 0 { parts.append("\(flight) sending") }
        if let unlinked = deliveries.unlinked, unlinked > 0 { parts.append("\(unlinked) unlinked") }
        return parts.isEmpty ? "All delivered" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func helpersSection(_ report: HostHealth) -> some View {
        if let helpers = report.helpers {
            Section {
                LabeledContent("Commit", value: helpers.commit.map { String($0.prefix(7)) + (helpers.dirty == true ? " (modified)" : "") }
                    ?? "Unknown")
                if let installed = HubDates.date(from: helpers.installedAt) {
                    LabeledContent("Installed") { Text(installed, format: .relative(presentation: .named)) }
                }
                if let digest = helpers.digest {
                    LabeledContent("Fingerprint", value: digest).monospaced()
                }
            } header: {
                Text("Host Scripts").textCase(nil)
            } footer: {
                Text("Two computers with the same fingerprint have the same scripts.")
            }
        }
    }

    // MARK: Loading

    private func loadHub() async {
        do {
            snapshot = try await store.computerHealth(computerId: computer.id)
            hubError = nil
        } catch TodoHubError.notFound {
            hubError = "The todo server doesn't keep health reports yet."
        } catch {
            hubError = (error as? TodoHubError)?.userMessage ?? error.localizedDescription
        }
    }

    private func checkLive() async {
        guard HostLookup.host(for: computer, in: hosts) != nil, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let config = try HostLookup.config(for: computer, in: hosts)
            let next = try await RemoteHealth.fetch(config: config, computerName: computer.name)
            guard !Task.isCancelled else { return }
            live = next
            liveError = nil
        } catch {
            guard !Task.isCancelled else { return }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            liveError = snapshot?.report == nil
                ? "Couldn't reach \(computer.name): \(reason)"
                : "Couldn't reach \(computer.name), so this is its last report. \(reason)"
        }
    }
}

/// One conversation the Health page offers to restart.
private struct HealthRestart {
    let conversation: Conversation
    let title: String
    let detail: String
    var refusal: String?
}
