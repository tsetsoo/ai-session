import AISessionCore
import SwiftData
import SwiftUI

/// Sending review items to the conversation without the review window: the phone's list.
/// One item at a time, on the revision it was written on (there's no diff here to move it).
@MainActor
enum ReviewItemSender {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static let offlineMessage = "The hub can't be reached, so reviews are read-only until it's back."

    /// Why an item can't be sent to this conversation now, or nil.
    static func blocker(_ conversation: Conversation, hubOffline: Bool) -> String? {
        if hubOffline { return offlineMessage }
        if conversation.tmuxName.isEmpty { return "This conversation has no terminal session." }
        switch conversation.status {
        case .waiting: return "The agent is waiting on a question. Answer it first."
        case .busy: return "The agent is working. Send once it has finished its turn."
        case .closed: return "The conversation is closed. Open it first."
        default: return nil
        }
    }

    /// Claims the item on the hub as sent (only if it is still as this device saw it, so two
    /// devices can't both type it), types it into the conversation in a batch of its own, and
    /// puts it back if the typing failed.
    static func send(_ id: UUID, conversation: Conversation, store: ReviewStore, hubOffline: Bool,
                     config: HostConnectionConfig,
                     exec: (HostConnectionConfig, String) async throws -> SSHExecResult) async throws {
        if let blocker = blocker(conversation, hubOffline: hubOffline) { throw Failure(errorDescription: blocker) }
        let key = conversation.listKey
        guard let comment = store.record(key).comments.first(where: { $0.id == id }), comment.state.isOpen else {
            throw Failure(errorDescription: "It was sent or dismissed already.")
        }
        let batch = ReviewBatch(commentIDs: [id], revision: comment.revision, statusRevision: conversation.statusRevision)
        try await claim(store, key: key, id: id, UpdateReviewItemRequest(
            state: ReviewComment.State.sent.rawValue, sentAt: ReviewSync.string(from: batch.sentAt),
            sentInTurn: batch.statusRevision, batchId: batch.id.uuidString, sentRevision: batch.revision,
            expectedState: comment.state.rawValue
        ), batch: batch)
        do {
            let message = ReviewMessage.render([comment], branch: conversation.branch, revision: comment.revision,
                                               includesUncommitted: false)
            // Keeps the revision from gc on the computer; a gone worktree mustn't stop the send.
            _ = try? await exec(config, TmuxCommandBuilder.reviewKeep(cwd: conversation.cwd, revision: comment.revision))
            let sent = try await exec(config, TmuxCommandBuilder.reviewSend(tmuxName: conversation.tmuxName, message: message))
            switch sent.exitCode {
            case TmuxCommandBuilder.reviewNoSessionExitCode:
                throw Failure(errorDescription: "The conversation isn't running on \(conversation.computer.name). Open it, then send again.")
            case TmuxCommandBuilder.reviewNotReadyExitCode:
                throw Failure(errorDescription: "The conversation can't take a message yet. Try again once it has started.")
            default:
                try RemoteConversations.check(sent, computerName: conversation.computer.name)
            }
        } catch {
            try? await store.patchItem(key, id: id, UpdateReviewItemRequest(
                state: comment.state.rawValue, expectedState: ReviewComment.State.sent.rawValue, clearSent: true))
            throw error
        }
    }

    /// Dismiss, only if nobody acted on it meanwhile.
    static func dismiss(_ id: UUID, key: String, store: ReviewStore, hubOffline: Bool) async throws {
        if hubOffline { throw Failure(errorDescription: offlineMessage) }
        guard let comment = store.record(key).comments.first(where: { $0.id == id }) else { return }
        try await claim(store, key: key, id: id, UpdateReviewItemRequest(
            state: ReviewComment.State.dismissed.rawValue, expectedState: comment.state.rawValue))
    }

    private static func claim(_ store: ReviewStore, key: String, id: UUID, _ request: UpdateReviewItemRequest,
                              batch: ReviewBatch? = nil) async throws {
        do {
            try await store.patchItem(key, id: id, request, batch: batch)
        } catch TodoHubError.conflict {
            await store.refresh(key)
            throw Failure(errorDescription: "It changed on another device meanwhile. The list shows it as it is now.")
        } catch TodoHubError.unreachable {
            throw Failure(errorDescription: offlineMessage)
        }
    }
}

/// The conversation's open review items (comments and findings not sent or dismissed), each
/// with Send and Dismiss. On the phone, from ⋯ ▸ Review; no diff here yet.
struct ReviewItemsSheet: View {
    /// As the sheet was opened; `conversation` follows the hub's newer copy (its status).
    let opened: Conversation
    let hub: TodoHubStore

    @Environment(\.dismiss) private var dismiss
    @Query private var hosts: [HostEntity]
    @State private var store = ReviewStore.shared
    @State private var sending: UUID?
    @State private var failure: String?

    private var key: String { opened.listKey }
    private var conversation: Conversation {
        hub.conversations.values.first { $0.listKey == opened.listKey } ?? opened
    }

    private var open: [ReviewComment] {
        store.record(key).comments
            .filter(\.state.isOpen)
            .sorted {
                (ReviewFindings.rank($0.severity), $0.path, $0.startLine ?? 0)
                    < (ReviewFindings.rank($1.severity), $1.path, $1.startLine ?? 0)
            }
    }

    var body: some View {
        NavigationStack {
            List {
                if let run = store.record(key).lastRun {
                    Section {
                        RunLine(run: run)
                    }
                }
                if let blocker = ReviewItemSender.blocker(conversation, hubOffline: hub.isOffline) {
                    Section {
                        Label(blocker, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section(open.isEmpty ? "" : (open.count == 1 ? "1 Open" : "\(open.count) Open")) {
                    ForEach(open) { comment in
                        ItemRow(comment: comment)
                            .swipeActions(edge: .trailing) {
                                Button("Dismiss") { dismissItem(comment.id) }
                                    .tint(.gray)
                            }
                            .swipeActions(edge: .leading) {
                                Button("Send") { send(comment.id) }
                                    .tint(DS.accent)
                            }
                            .contextMenu {
                                Button("Send to Agent", systemImage: "paperplane") { send(comment.id) }
                                Button("Dismiss", systemImage: "xmark") { dismissItem(comment.id) }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                HStack(spacing: DS.spacing.m) {
                                    Button("Dismiss") { dismissItem(comment.id) }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.secondary)
                                    Button {
                                        send(comment.id)
                                    } label: {
                                        if sending == comment.id { ProgressView() } else { Text("Send") }
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(sending != nil || ReviewItemSender.blocker(conversation, hubOffline: hub.isOffline) != nil)
                                }
                                .font(.callout.weight(.semibold))
                            }
                    }
                }
            }
            .overlay {
                if open.isEmpty {
                    ContentUnavailableView("Nothing Open", systemImage: "checklist",
                                           description: Text("Review on the Mac (⌥⌘R ▸ Review) to have Claude or Codex read the changes. Its findings show here."))
                }
            }
            .navigationTitle("Review")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await store.refresh(key) }
            .task { await store.refresh(key) }
            // Another device sent or dismissed something.
            .onChange(of: hub.reviewSummaries[key]) { _, _ in Task { await store.refresh(key) } }
            .alert("Review", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func dismissItem(_ id: UUID) {
        Task {
            do {
                try await ReviewItemSender.dismiss(id, key: key, store: store, hubOffline: hub.isOffline)
            } catch {
                failure = (error as? ReviewItemSender.Failure)?.errorDescription
                    ?? ConversationRowActions.message(for: error, computer: conversation.computer)
            }
        }
    }

    private func send(_ id: UUID) {
        guard sending == nil else { return }
        sending = id
        Task {
            defer { sending = nil }
            do {
                let config = try HostLookup.config(for: conversation.computer, in: hosts)
                try await ReviewItemSender.send(id, conversation: conversation, store: store, hubOffline: hub.isOffline,
                                                config: config) {
                    try await NIOSSHClient().exec($0, command: $1)
                }
            } catch {
                failure = (error as? ReviewItemSender.Failure)?.errorDescription
                    ?? ConversationRowActions.message(for: error, computer: conversation.computer)
            }
        }
    }
}

private struct RunLine: View {
    let run: ReviewRun

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(run.tool.capitalized) review")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(run.startedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Group {
                switch run.state {
                case .running: Text("Reviewing on the computer…")
                case .failed: Text(run.error ?? "The review failed.")
                case .cancelled: Text("Cancelled.")
                case .done: Text(run.summary ?? "Done.")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ItemRow: View {
    let comment: ReviewComment

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.xs) {
            HStack(spacing: DS.spacing.s) {
                if let author = comment.prAuthor {
                    Text("PR · \(author)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.accent)
                } else if let severity = comment.severity {
                    Text(severity.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(severity == "high" ? DS.error : severity == "low" ? Color.secondary : DS.warning, in: Capsule())
                } else {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.accent)
                }
                Text(comment.location)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if comment.state == .draft {
                    Text("In next batch")
                        .font(.caption)
                        .foregroundStyle(DS.accent)
                }
            }
            if !comment.quote.isEmpty {
                Text(comment.quote.prefix(3).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let title = comment.title {
                Text(title).font(.subheadline.weight(.semibold))
            }
            Text(comment.body)
                .font(.subheadline)
                .lineLimit(6)
                // Room for the buttons in the corner.
                .padding(.bottom, 24)
        }
        .padding(.vertical, DS.spacing.xs)
    }
}
