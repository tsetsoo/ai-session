import AISessionCore
import SwiftUI

/// "5 min ago" for a hub time.
@MainActor
private func ago(_ hubTime: String?) -> String {
    guard let date = HubDates.date(from: hubTime) else { return "–" }
    return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
}

/// The list's content, shared by the Mac (selectable rows) and the phone (pushed rows): watch
/// jobs' last checks, open issues by group, then the ones cleared in the last 7 days.
struct WatchersListContent<Row: View>: View {
    let store: TodoHubStore
    /// The Mac's selected issue; nil on the phone, whose rows push.
    var selection: Binding<String?>?
    @ViewBuilder let row: (WatchIssue) -> Row

    private var watchJobs: [(SchedulerJob, WatchJobAction)] {
        store.jobs.compactMap { job in
            if case let .watch(w) = job.action { return (job, w) }
            return nil
        }
    }

    var body: some View {
        List(selection: selection ?? .constant(nil)) {
            if watchJobs.isEmpty {
                Text("No watch jobs yet. Make one in Jobs (Does: Watch).").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(watchJobs, id: \.0.id) { job, watch in
                WatchJobStatus(job: job, watch: watch)
            }
            if store.openWatchIssues.isEmpty && !watchJobs.isEmpty {
                Label("No open issues", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            ForEach(WatchIssueGrouping.grouped(store.openWatchIssues), id: \.group) { group in
                Section("\(group.group.title) · \(group.issues.count)") {
                    ForEach(group.issues) { issue in row(issue) }
                }
            }
            if !store.recentWatchIssues.isEmpty {
                Section("Cleared in the last 7 days") {
                    ForEach(store.recentWatchIssues) { issue in row(issue) }
                }
            }
        }
        .task(id: store.revision) { await store.loadRecentWatchIssues() }
    }
}

/// One watch job's last check, and why it failed.
private struct WatchJobStatus: View {
    let job: SchedulerJob
    let watch: WatchJobAction

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(job.name, systemImage: job.enabled ? "eye" : "eye.slash").font(.callout.weight(.medium))
            if let run = job.lastRun {
                if run.state == "failed" {
                    Text("Last check failed \(ago(run.updatedAt)): \(run.result ?? "")")
                        .font(.caption).foregroundStyle(DS.warning).lineLimit(3)
                } else {
                    Text("Last check \(ago(run.updatedAt)) · \(run.state)").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(job.enabled ? "Not checked yet" : "Off").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct WatchIssueRow: View {
    let issue: WatchIssue
    let store: TodoHubStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(issue.title).lineLimit(2)
            HStack(spacing: 6) {
                if let folder = issue.folder { Text(folder) }
                Text("first \(ago(issue.firstSeen)) · last \(ago(issue.lastSeen))")
                if issue.todoId != nil { Image(systemName: "bubble.left").accessibilityLabel("Has a conversation") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let error = issue.resolveError {
                Text(error).font(.caption).foregroundStyle(DS.warning).lineLimit(1)
            }
        }
    }
}

/// Automation → Watchers, list column (Mac).
struct WatchersList: View {
    let store: TodoHubStore
    @Binding var selection: String?

    var body: some View {
        WatchersListContent(store: store, selection: $selection) { issue in
            WatchIssueRow(issue: issue, store: store).tag(issue.id)
        }
        .navigationTitle("Watchers")
    }
}

/// Automation → Watchers, big pane: one issue and what to do about it.
struct WatchIssueDetail: View {
    let store: TodoHubStore
    let issueID: String?
    let onOpenTodo: (String) -> Void

    @Environment(\.openURL) private var openURL
    @State private var confirmingResolve = false
    @State private var working = false
    @State private var errorMessage: String?

    private var issue: WatchIssue? {
        guard let issueID else { return nil }
        return store.openWatchIssues.first { $0.id == issueID } ?? store.recentWatchIssues.first { $0.id == issueID }
    }

    var body: some View {
        if let issue {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(issue.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(issue.state == "cleared" ? "Cleared" : issue.group.title)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        if let folder = issue.folder { Text(folder).font(.caption).foregroundStyle(.secondary) }
                        Text("first seen \(ago(issue.firstSeen)) · last \(ago(issue.lastSeen))").font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = issue.outcomeNote, !note.isEmpty {
                        Label(note, systemImage: "text.bubble").textSelection(.enabled)
                    }
                    if let error = issue.resolveError {
                        Label("Resolve failed: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
                    }
                    actions(issue)
                    Divider()
                    Text(issue.details.isEmpty ? "No details." : issue.details)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(issue.key)
            .confirmationDialog("Resolve “\(issue.title)” in \(issue.watcher.capitalized)?", isPresented: $confirmingResolve) {
                Button("Resolve") { run { try await store.resolveWatchIssue(issue) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Do this once the fix is deployed. If it happens again, it comes back as a new issue.")
            }
        } else {
            AutomationEmpty(text: store.openWatchIssues.isEmpty ? "No open issues." : "Choose an issue to see its details.")
        }
    }

    @ViewBuilder
    private func actions(_ issue: WatchIssue) -> some View {
        let buttons = Group {
            if let url = URL(string: issue.url), !issue.url.isEmpty {
                Button { openURL(url) } label: { Label("Open in \(issue.watcher.capitalized)", systemImage: "safari") }
            }
            if let todo = issue.todoId {
                Button { onOpenTodo(todo) } label: { Label("Open Conversation", systemImage: "bubble.left") }
            }
            if issue.state == "open" {
                Button { confirmingResolve = true } label: { Label("Resolve in \(issue.watcher.capitalized)", systemImage: "checkmark.circle") }
            }
            if issue.state == "resolving" {
                Label("Resolving… this Mac does it within a minute", systemImage: "hourglass").foregroundStyle(.secondary)
            }
            if issue.canRetry && issue.state == "open" {
                Button { run { try await store.retryWatchIssue(issue) } } label: { Label("Try Again", systemImage: "arrow.clockwise") }
            }
        }
        #if os(macOS)
        HStack { buttons }.disabled(working || store.isOffline)
        #else
        VStack(alignment: .leading, spacing: 10) { buttons }.disabled(working || store.isOffline)
        #endif
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        errorMessage = nil
        Task {
            do { try await action() } catch { errorMessage = error.localizedDescription }
            working = false
        }
    }
}
