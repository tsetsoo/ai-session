#if os(iOS)
import AISessionCore
import SwiftUI

/// One delegated worker: its result first (Read Aloud reads it), then what it did and the task
/// it was given, both folded. What it did is fetched only when unfolded, and kept fresh while
/// the worker works.
struct WorkerSheet: View {
    let worker: DelegatedWorker
    let conversation: Conversation
    let config: HostConnectionConfig
    let store: TodoHubStore
    let toolName: String

    @Environment(\.dismiss) private var dismiss
    @State private var showsActivity = Self.demoUnfolded
    @State private var showsTask = false
    @State private var activity: [ConversationMessage] = []
    @State private var activityError: String?
    @State private var loadingActivity = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    result
                    DisclosureGroup(isExpanded: $showsActivity) { activityList } label: {
                        Text("What it did").font(.headline)
                    }
                    if let task = worker.task {
                        DisclosureGroup(isExpanded: $showsTask) {
                            Text(task)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        } label: {
                            Text("Task").font(.headline)
                        }
                    }
                    // A working worker's evidence is "last write N s ago", frozen; the header counts.
                    if worker.state != .working, let evidence = worker.evidence {
                        Text("How this is known: \(evidence)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle(worker.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } }
            }
            .task(id: ActivityPoll(open: showsActivity, working: worker.state == .working)) { await pollActivity() }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                WorkerStateLabel(state: worker.state)
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if worker.state != .done, let status = worker.statusText(now: context.date) {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            let details = [worker.kind, worker.model, worker.statsLine.isEmpty ? nil : worker.statsLine]
                .compactMap { $0 }.joined(separator: " · ")
            if !details.isEmpty {
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        if let text = worker.result {
            ChatMessageView(message: ConversationMessage(id: "worker-result-" + worker.id, role: .assistant, text: text), toolName: toolName)
        } else {
            Text(placeholder).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var placeholder: String {
        switch worker.state {
        case .working: "The result shows here when it reports back."
        case .stale: "No result recorded yet."
        case .failed: "It stopped without a result."
        case .done: "It finished without a written result."
        }
    }

    @ViewBuilder
    private var activityList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let activityError {
                Text(activityError).font(.footnote).foregroundStyle(.secondary)
            } else if activity.isEmpty {
                if loadingActivity { ProgressView().frame(maxWidth: .infinity) }
                else { Text("Nothing recorded yet.").font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(ChatTimeline.items(entries: activity, pending: [], notes: [])) { item in
                switch item {
                case let .time(_, date): ChatTimestamp(date: date)
                case let .message(message): ChatMessageView(message: message, toolName: worker.displayTitle)
                case let .activity(_, steps, summary): ChatActivityRow(steps: steps, summary: summary, isLive: false)
                case .pending, .note, .delegation: EmptyView()
                }
            }
        }
        .padding(.top, 6)
    }

    private static var demoUnfolded: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiDemoWorkerActivity")
        #else
        false
        #endif
    }

    private struct ActivityPoll: Equatable {
        let open: Bool
        let working: Bool
    }

    /// Once on unfolding, then every 3 s with only the new lines while it works.
    private func pollActivity() async {
        guard showsActivity else { return }
        repeat {
            loadingActivity = activity.isEmpty
            do {
                let fetched = try await store.workerMessages(
                    of: conversation, workerId: worker.id, config: config, previous: activity
                )
                guard !Task.isCancelled else { return }
                if fetched != activity { activity = fetched }
                activityError = nil
            } catch is RemoteConversations.OldHelper {
                activityError = "Update the todo helpers on \(conversation.computer.name) to see this."
                loadingActivity = false
                return
            } catch is RemoteConversations.NoTranscript {
                activityError = activity.isEmpty ? "Nothing recorded on \(conversation.computer.name)." : nil
            } catch {
                guard !Task.isCancelled else { return }
                activityError = activity.isEmpty ? "Couldn’t load what it did." : nil
            }
            loadingActivity = false
            guard worker.state == .working else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        } while !Task.isCancelled
    }
}
#endif
