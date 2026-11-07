#if os(macOS)
import AISessionCore
import SwiftData
import SwiftUI

/// ⋯ ▸ Workers on the Mac: the conversation's delegated work as cards, and one worker's result,
/// steps and task when a card is clicked. The Mac shows the terminal, not the chat, so the cards
/// live here instead of in the transcript. Built only while the inspector is open; it asks the
/// computer again every 10 s while a worker works and every 30 s otherwise.
struct WorkersPanel: View {
    let conversation: Conversation
    let store: TodoHubStore

    @Query private var hosts: [HostEntity]
    @State private var workers: [DelegatedWorker] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var selectedID: String? = Self.demoSelection
    @State private var config: HostConnectionConfig?

    static let idleInterval: TimeInterval = 30

    var body: some View {
        Group {
            if let selected, let config {
                detail(selected, config: config)
            } else {
                list
            }
        }
        .task { await poll() }
    }

    private var selected: DelegatedWorker? {
        selectedID.flatMap { id in workers.first { $0.id == id } }
    }

    private var toolName: String { RowText.toolName(conversation.tool) }

    @ViewBuilder
    private var list: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let problem, workers.isEmpty {
            ContentUnavailableView("Workers Unavailable", systemImage: "person.2", description: Text(problem))
        } else if workers.isEmpty {
            ContentUnavailableView(
                "No Workers", systemImage: "person.2",
                description: Text(emptyText)
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    // Newest first: the one just started is the one to watch.
                    ForEach(workers.reversed()) { worker in
                        ChatWorkerCard(worker: worker) { selectedID = worker.id }
                    }
                }
                .padding(12)
            }
        }
    }

    private var emptyText: String {
        ["claude", "codex"].contains(conversation.tool)
            ? "Subagents and spawned agents this conversation starts show up here."
            : "\(toolName) doesn’t record delegated work."
    }

    /// "3 workers · 1 working · 2 done".
    private var summary: String {
        var parts = ["\(workers.count) \(workers.count == 1 ? "worker" : "workers")"]
        for (state, word) in [(DelegatedWorker.State.working, "working"), (.failed, "failed"), (.stale, "no news"), (.done, "done")] {
            let n = workers.filter { $0.state == state }.count
            if n > 0 { parts.append("\(n) \(word)") }
        }
        return parts.joined(separator: " · ")
    }

    private func detail(_ worker: DelegatedWorker, config: HostConnectionConfig) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedID = nil
            } label: {
                Label("All Workers", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                WorkerDetail(
                    worker: worker, conversation: conversation, config: config, store: store,
                    toolName: toolName, showsTitle: true,
                    // Live steps are what this panel is for on the Mac.
                    activityOpen: true
                )
                .padding(12)
            }
            .id(worker.id)
        }
    }

    private func poll() async {
        do {
            config = try Self.demoConfig ?? HostLookup.config(for: conversation.computer, in: hosts)
        } catch {
            problem = TodoHubStore.message(for: error)
            loaded = true
            return
        }
        while !Task.isCancelled {
            guard let config else { return }
            do {
                let fetched = try await store.delegatedWorkers(of: conversation, config: config)
                guard !Task.isCancelled else { return }
                if fetched != workers { workers = fetched }
                problem = nil
            } catch is RemoteConversations.NoTranscript {
                problem = nil
            } catch {
                guard !Task.isCancelled else { return }
                // Keep the last list; say so only when there is nothing to show.
                problem = "Couldn’t reach \(conversation.computer.name): \(TodoHubStore.message(for: error))"
            }
            loaded = true
            let working = workers.contains { $0.state == .working }
            let wait = working ? Delegation.workingInterval : Self.idleInterval
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
        }
    }

    private static var demoConfig: HostConnectionConfig? {
        #if DEBUG
        if DemoFixtures.isEnabled { return DemoFixtures.config }
        #endif
        return nil
    }

    private static var demoSelection: String? {
        #if DEBUG
        if DemoFixtures.isEnabled { return DemoFixtures.value(after: "-uiDemoWorker") }
        #endif
        return nil
    }
}
#endif
