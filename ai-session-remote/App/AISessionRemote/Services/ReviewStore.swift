import AISessionCore
import Foundation
import Observation

/// Review comments, findings, sent batches and reviewer runs per conversation
/// (`Conversation.listKey`, the hub's conversation id). The hub has the real copy
/// (`/api/reviews`); this is its cache on the device, kept in a local file so the review
/// window and the phone's list open with what was last seen.
///
/// A change applies here at once, then the rows it touched are written to the hub. Rows the
/// hub didn't take yet (offline, an error) stay pending, in the file too; they are written
/// again with the next change, the next refresh, or a retry a little later, and a refresh
/// keeps them as they are here. A row the hub refuses (400) is left here and reported.
@Observable
@MainActor
final class ReviewStore {
    static let shared = ReviewStore()

    private(set) var records: [String: ReviewRecord] = [:]
    /// The last write or read failed because the hub couldn't be reached. Changes still apply
    /// here and go once it's back.
    private(set) var isOffline = false
    /// The last failure that wasn't about reaching the hub (a refused row), for the window.
    private(set) var problem: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let makeClient: () -> TodoHubClient?
    @ObservationIgnored private let retryDelay: Duration
    /// Per conversation: rows changed here that the hub hasn't taken yet.
    @ObservationIgnored private var pending: [String: ReviewSync.Touched] = [:]
    @ObservationIgnored private var pushing: Set<String> = []
    /// Bumped by every local change and every write the hub took, per conversation: a read
    /// that started before a bump is older than what's here and isn't applied.
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    /// The file's shape: the records, and what is still to be written to the hub.
    private struct Saved: Codable {
        var records: [String: ReviewRecord]
        var pending: [String: ReviewSync.Touched]?
        /// The comments file of the local-only versions has been uploaded.
        var uploaded: Bool?
    }

    @ObservationIgnored private var uploaded = false

    init(fileURL: URL = ReviewStore.defaultURL, makeClient: @escaping () -> TodoHubClient? = TodoHubSettings.makeClient,
         retryDelay: Duration = .seconds(30)) {
        self.fileURL = fileURL
        self.makeClient = makeClient
        self.retryDelay = retryDelay
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode(Saved.self, from: data) {
            records = saved.records
            pending = saved.pending ?? [:]
            uploaded = saved.uploaded ?? false
        } else if let local = try? decoder.decode([String: ReviewRecord].self, from: data) {
            // The local-only file of earlier versions: everything in it still has to go up.
            records = local
            keepBackup()
        } else {
            // Unreadable (cut short, or written by a newer version): keep it beside the new
            // file instead of letting the first save overwrite every conversation's comments.
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // The unsandboxed Mac app shares Application Support with every other app.
        let folder = Bundle.main.bundleIdentifier ?? "AISessionRemote"
        return base.appendingPathComponent(folder).appendingPathComponent("review-comments.json")
    }

    /// The local-only file as it was, once, next to it.
    private func keepBackup() {
        let backup = fileURL.deletingPathExtension().appendingPathExtension("before-hub.json")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: fileURL, to: backup)
        }
    }

    func record(_ key: String) -> ReviewRecord {
        records[key] ?? ReviewRecord()
    }

    /// Rows of this conversation the hub hasn't taken yet, or a write of them is under way.
    func isSyncing(_ key: String) -> Bool { pending[key] != nil || pushing.contains(key) }

    /// A write of this conversation's rows is under way.
    func isPushing(_ key: String) -> Bool { pushing.contains(key) }

    /// Changes a conversation's record here and writes the rows it touched to the hub.
    func update(_ key: String, _ change: (inout ReviewRecord) -> Void) {
        let old = record(key)
        var new = old
        change(&new)
        records[key] = new
        generations[key, default: 0] += 1
        var touched = pending[key] ?? ReviewSync.Touched()
        touched.merge(ReviewSync.touched(from: old, to: new))
        pending[key] = touched.isEmpty ? nil : touched
        save()
        if !touched.isEmpty { Task { await push(key) } }
    }

    /// The hub's copy of a conversation's record, with this device's unwritten changes kept.
    func refresh(_ key: String) async {
        guard let client = makeClient(), !key.isEmpty else { return }
        await uploadIfNeeded()
        // Until the old file is up, the hub's empty copy would replace it here.
        guard uploaded else { return }
        await push(key)
        let generation = generations[key, default: 0]
        do {
            let hub = try await client.reviewRecord(conversationId: key)
            isOffline = false
            // Something changed here, or a write landed, while this read was out: it may not
            // show that yet. The next refresh will.
            guard generation == generations[key, default: 0], !pushing.contains(key) else { return }
            let fetched = ReviewSync.record(hub)
            let merged = ReviewSync.merge(hub: fetched, local: record(key), pending: pending[key] ?? .init())
            if records[key] != merged {
                records[key] = merged
                save()
            }
        } catch {
            note(error)
        }
    }

    /// Writes this conversation's pending rows, again and again while changes keep coming
    /// in during a write. One writer per conversation.
    func push(_ key: String) async {
        guard let client = makeClient(), !pushing.contains(key) else { return }
        pushing.insert(key)
        defer { pushing.remove(key) }
        while let touched = pending[key], !touched.isEmpty {
            let request = ReviewSync.request(touched, in: record(key), conversationID: key)
            do {
                if !request.isEmpty { try await client.reviewBatch(request) }
                isOffline = false
                problem = nil
                taken(request, key: key)
            } catch TodoHubError.badRequest(let message) {
                // One row the hub won't take mustn't hold back the others: each on its own,
                // and the refused ones stay here only.
                if await !pushOneByOne(request, key: key, client: client, firstError: message) { return }
            } catch {
                note(error)
                return
            }
        }
    }

    /// A rejected batch, row by row. Refused rows leave `pending`; the rest are written.
    /// False when the hub stopped answering meanwhile.
    private func pushOneByOne(_ request: ReviewBatchRequest, key: String, client: TodoHubClient, firstError: String) async -> Bool {
        var refused: [String] = []
        let singles = request.reviews.map { ReviewBatchRequest(reviews: [$0]) }
            + request.items.map { ReviewBatchRequest(items: [$0]) }
            + (request.deleteItems.isEmpty ? [] : [ReviewBatchRequest(deleteItems: request.deleteItems)])
        for single in singles {
            do {
                try await client.reviewBatch(single)
                taken(single, key: key)
            } catch TodoHubError.badRequest(let message) {
                refused.append(message)
                drop(single, key: key)
            } catch {
                note(error)
                return false
            }
        }
        if refused.isEmpty {
            // Each row went on its own: the batch's trouble was elsewhere (its size).
            problem = nil
        } else {
            problem = "The hub didn't keep \(refused.count == 1 ? "a review item" : "\(refused.count) review items"): "
                + (refused.first ?? firstError)
        }
        // What's still pending changed meanwhile and goes in the next round.
        return true
    }

    /// The hub has these rows: they leave `pending` unless they changed again meanwhile.
    private func taken(_ request: ReviewBatchRequest, key: String) {
        guard var remaining = pending[key] else { return }
        let current = ReviewSync.request(
            .init(items: Set(request.items.compactMap { UUID(uuidString: $0.id) }),
                  runs: Set(request.reviews.compactMap { UUID(uuidString: $0.id) })),
            in: record(key), conversationID: key
        )
        for item in request.items where current.items.first(where: { $0.id == item.id }) == item {
            if let id = UUID(uuidString: item.id) { remaining.items.remove(id) }
        }
        for review in request.reviews where current.reviews.first(where: { $0.id == review.id }) == review {
            if let id = UUID(uuidString: review.id) { remaining.runs.remove(id) }
        }
        remaining.deletedItems.subtract(request.deleteItems.compactMap(UUID.init(uuidString:)))
        pending[key] = remaining.isEmpty ? nil : remaining
        generations[key, default: 0] += 1
        save()
    }

    private func drop(_ request: ReviewBatchRequest, key: String) {
        guard var remaining = pending[key] else { return }
        remaining.items.subtract(request.items.compactMap { UUID(uuidString: $0.id) })
        remaining.runs.subtract(request.reviews.compactMap { UUID(uuidString: $0.id) })
        remaining.deletedItems.subtract(request.deleteItems.compactMap(UUID.init(uuidString:)))
        pending[key] = remaining.isEmpty ? nil : remaining
        save()
    }

    /// Every conversation's pending rows.
    func pushAll() async {
        for key in pending.keys.sorted() { await push(key) }
    }

    /// Changes one item on the hub only if it is still in `expected` there (Send and Dismiss
    /// on the phone): another device may have acted on it meanwhile. The hub's row then
    /// replaces this one. Throws `TodoHubError.conflict` when it had changed.
    func patchItem(_ key: String, id: UUID, _ request: UpdateReviewItemRequest, batch: ReviewBatch? = nil) async throws {
        guard let client = makeClient() else { throw TodoHubError.unreachable("No hub") }
        let row: HubReviewItem
        do {
            row = try await client.updateReviewItem(id: id.uuidString, request)
        } catch {
            if case TodoHubError.unreachable = error { isOffline = true }
            throw error
        }
        isOffline = false
        guard let comment = ReviewSync.comment(row) else { return }
        var record = record(key)
        if let index = record.comments.firstIndex(where: { $0.id == id }) {
            record.comments[index] = comment
        } else {
            record.comments.append(comment)
        }
        if let batch, !record.batches.contains(where: { $0.id == batch.id }) { record.batches.append(batch) }
        records[key] = record
        generations[key, default: 0] += 1
        save()
    }

    /// The local-only versions kept everything in this file: once, all of it goes to the hub.
    /// A conversation the hub refuses is reported and left here, not retried forever.
    func uploadIfNeeded() async {
        guard !uploaded, let client = makeClient() else { return }
        for (key, record) in records.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            let request = ReviewSync.everything(record, conversationID: key)
            guard !request.isEmpty else { continue }
            do {
                try await client.reviewBatch(request)
            } catch TodoHubError.badRequest(let message) {
                problem = "Some earlier review comments couldn't be copied to the hub: \(message)"
            } catch {
                note(error)
                return
            }
        }
        uploaded = true
        save()
    }

    private func note(_ error: Error) {
        if case TodoHubError.unreachable = error {
            isOffline = true
            scheduleRetry()
        } else {
            problem = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// After the hub was unreachable: try the pending rows again a little later, and keep
    /// trying while it stays away.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let delay = retryDelay
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            await self.pushAll()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let saved = Saved(records: records, pending: pending, uploaded: uploaded)
        guard let data = try? encoder.encode(saved) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
