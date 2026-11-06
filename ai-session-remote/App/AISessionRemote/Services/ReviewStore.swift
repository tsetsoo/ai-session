import AISessionCore
import Foundation
import Observation

/// Review comments, findings, sent batches and reviewer runs per conversation
/// (`Conversation.listKey`, the hub's conversation id). The hub has the real copy
/// (`/api/reviews`); this is its cache on the device, kept in a local file so the review
/// window and the phone's list open with what was last seen.
///
/// A change applies here at once, then the rows it touched are written to the hub. Rows the
/// hub didn't take yet (offline, an error) stay pending, in the file too, and go with the next
/// change or refresh; a refresh keeps them as they are here. While the hub is unreachable
/// the windows treat reviews as read-only (`isOffline`).
@Observable
@MainActor
final class ReviewStore {
    static let shared = ReviewStore()

    private(set) var records: [String: ReviewRecord] = [:]
    /// The last write or read failed because the hub couldn't be reached.
    private(set) var isOffline = false
    /// The last failure that wasn't about reaching the hub (a rejected write), for the window.
    private(set) var problem: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let makeClient: () -> TodoHubClient?
    /// Per conversation: rows changed here that the hub hasn't taken yet.
    @ObservationIgnored private var pending: [String: ReviewSync.Touched] = [:]
    @ObservationIgnored private var pushing: Set<String> = []

    /// The file's shape: the records, and what is still to be written to the hub.
    private struct Saved: Codable {
        var records: [String: ReviewRecord]
        var pending: [String: ReviewSync.Touched]?
        /// The comments file of the local-only versions has been uploaded.
        var uploaded: Bool?
    }

    @ObservationIgnored private var uploaded = false

    init(fileURL: URL = ReviewStore.defaultURL, makeClient: @escaping () -> TodoHubClient? = TodoHubSettings.makeClient) {
        self.fileURL = fileURL
        self.makeClient = makeClient
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

    /// Changes a conversation's record here and writes the rows it touched to the hub.
    func update(_ key: String, _ change: (inout ReviewRecord) -> Void) {
        let old = record(key)
        var new = old
        change(&new)
        records[key] = new
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
        do {
            let hub = try await client.reviewRecord(conversationId: key)
            isOffline = false
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

    /// Writes this conversation's pending rows. One write per conversation at a time; changes
    /// made meanwhile go with the next one.
    func push(_ key: String) async {
        guard let client = makeClient(), !pushing.contains(key), let touched = pending[key], !touched.isEmpty else { return }
        pushing.insert(key)
        defer { pushing.remove(key) }
        let request = ReviewSync.request(touched, in: record(key), conversationID: key)
        do {
            if !request.isEmpty { try await client.reviewBatch(request) }
            isOffline = false
            problem = nil
            // Only what went: changes made while it was on its way stay pending.
            if var remaining = pending[key] {
                let sentItems = Set(request.items.compactMap { UUID(uuidString: $0.id) })
                let sentRuns = Set(request.reviews.compactMap { UUID(uuidString: $0.id) })
                let sentDeletes = Set(request.deleteItems.compactMap { UUID(uuidString: $0) })
                let current = record(key)
                let now = ReviewSync.request(.init(items: sentItems, runs: sentRuns), in: current, conversationID: key)
                // A row changed again since it was read for this write is still pending.
                let unchangedItems = Set(zip(request.items, request.items.map { item in now.items.first { $0.id == item.id } })
                    .compactMap { $0 == $1 ? UUID(uuidString: $0.id) : nil })
                let unchangedRuns = Set(zip(request.reviews, request.reviews.map { review in now.reviews.first { $0.id == review.id } })
                    .compactMap { $0 == $1 ? UUID(uuidString: $0.id) : nil })
                remaining.items.subtract(unchangedItems)
                remaining.runs.subtract(unchangedRuns)
                remaining.deletedItems.subtract(sentDeletes)
                pending[key] = remaining.isEmpty ? nil : remaining
                save()
            }
        } catch {
            note(error)
        }
        if pending[key] != nil, !isOffline, problem == nil {
            // Changed while this write was out: write those too.
            await push(key)
        }
    }

    /// Rows of this conversation the hub hasn't taken yet, or a write of them is under way.
    func isSyncing(_ key: String) -> Bool { pending[key] != nil || pushing.contains(key) }

    /// A write of this conversation's rows is under way.
    func isPushing(_ key: String) -> Bool { pushing.contains(key) }

    /// Every conversation's pending rows (after the hub comes back).
    func pushAll() async {
        for key in pending.keys.sorted() { await push(key) }
    }

    /// The local-only versions kept everything in this file: once, all of it goes to the hub.
    func uploadIfNeeded() async {
        guard !uploaded, let client = makeClient() else { return }
        do {
            for (key, record) in records.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
                let request = ReviewSync.everything(record, conversationID: key)
                if !request.isEmpty { try await client.reviewBatch(request) }
            }
            uploaded = true
            save()
        } catch {
            note(error)
        }
    }

    private func note(_ error: Error) {
        if case TodoHubError.unreachable = error {
            isOffline = true
        } else {
            problem = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
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
