import Foundation

/// Between the review window's `ReviewRecord` and the hub's rows. Batches aren't rows of
/// their own: an item that went out carries its batch's id, revision and status revision.
public enum ReviewSync {
    // MARK: Dates

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// ISO 8601 with milliseconds: what goes to the hub.
    public static func string(from date: Date) -> String { fractional.string(from: date) }

    /// ISO 8601 with or without fractions, or the hub's own `2026-11-06 20:00:00` (UTC).
    public static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? whole.date(from: string) ?? HubDates.date(from: string)
    }

    // MARK: Rows

    /// The hub's limits (reviews.rs): longer text is cut here rather than refused there.
    public static let maxQuoteLines = 200
    public static let maxBody = 20_000
    public static let maxShort = 500

    public static func item(_ comment: ReviewComment, conversationID: String, batch: ReviewBatch?) -> HubReviewItem {
        func short(_ text: String?) -> String? { text.map { String($0.prefix(maxShort)) } }
        return HubReviewItem(
            id: comment.id.uuidString, reviewId: comment.runID?.uuidString, conversationId: conversationID,
            author: String(comment.author.prefix(maxShort)), fingerprint: short(comment.fingerprint),
            severity: short(comment.severity), category: short(comment.category), title: short(comment.title),
            path: String(comment.path.prefix(maxShort)), side: comment.side.rawValue,
            lineStart: comment.startLine, lineEnd: comment.endLine, revision: String(comment.revision.prefix(maxShort)),
            quote: Array(comment.quote.prefix(maxQuoteLines)),
            body: String(comment.body.prefix(maxBody)), state: comment.state.rawValue, sentAt: comment.sentAt.map(string(from:)),
            sentInTurn: batch?.statusRevision, batchId: comment.batchID?.uuidString, sentRevision: batch?.revision,
            createdAt: string(from: comment.createdAt)
        )
    }

    /// Nil for a row this version can't read (a bad id).
    public static func comment(_ item: HubReviewItem) -> ReviewComment? {
        guard let id = UUID(uuidString: item.id) else { return nil }
        // A state of a newer hub: open if it wasn't sent, as far as this version can tell.
        let state = ReviewComment.State(rawValue: item.state) ?? (item.sentAt == nil ? .new : .sent)
        return ReviewComment(
            id: id, author: item.author, path: item.path, side: DiffSide(rawValue: item.side) ?? .new,
            startLine: item.lineStart, endLine: item.lineEnd, revision: item.revision, quote: item.quote,
            body: item.body, state: state, createdAt: date(from: item.createdAt) ?? .distantPast,
            sentAt: item.sentAt.flatMap(date(from:)), batchID: item.batchId.flatMap(UUID.init(uuidString:)),
            severity: item.severity, category: item.category, title: item.title, fingerprint: item.fingerprint,
            runID: item.reviewId.flatMap(UUID.init(uuidString:))
        )
    }

    public static func review(_ run: ReviewRun, conversationID: String) -> HubReview {
        HubReview(
            id: run.id.uuidString, conversationId: conversationID, tool: run.tool, model: run.model, scope: run.scope,
            baseSha: run.baseSHA, reviewedSha: run.reviewedSHA, state: run.state.rawValue,
            startedAt: string(from: run.startedAt), finishedAt: run.finishedAt.map(string(from:)), summary: run.summary,
            error: run.error,
            usage: run.usage.map {
                HubReviewUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens,
                               cacheWriteTokens: $0.cacheWriteTokens, costUsd: $0.costUSD)
            },
            findingCount: run.findingCount, addedCount: run.addedCount
        )
    }

    public static func run(_ review: HubReview) -> ReviewRun? {
        guard let id = UUID(uuidString: review.id), let state = ReviewRunResult.State(rawValue: review.state) else { return nil }
        return ReviewRun(
            id: id, tool: review.tool, model: review.model, scope: review.scope, baseSHA: review.baseSha,
            reviewedSHA: review.reviewedSha, state: state, startedAt: date(from: review.startedAt) ?? .distantPast,
            finishedAt: review.finishedAt.flatMap(date(from:)), summary: review.summary, error: review.error,
            usage: review.usage.map {
                ReviewUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens,
                            cacheWriteTokens: $0.cacheWriteTokens, costUSD: $0.costUsd)
            },
            findingCount: review.findingCount, addedCount: review.addedCount
        )
    }

    /// The hub's rows as a record; batches are rebuilt from the items that went out.
    public static func record(_ hub: HubReviewRecord) -> ReviewRecord {
        let comments = hub.items.compactMap(comment)
        var batches: [UUID: ReviewBatch] = [:]
        for item in hub.items {
            guard let batchID = item.batchId.flatMap(UUID.init(uuidString:)), let id = UUID(uuidString: item.id) else { continue }
            let sentAt = item.sentAt.flatMap(date(from:)) ?? .distantPast
            if var batch = batches[batchID] {
                batch.commentIDs.append(id)
                batch.sentAt = min(batch.sentAt, sentAt)
                batches[batchID] = batch
            } else {
                batches[batchID] = ReviewBatch(id: batchID, commentIDs: [id], revision: item.sentRevision ?? item.revision,
                                               sentAt: sentAt, statusRevision: item.sentInTurn)
            }
        }
        return ReviewRecord(comments: comments, batches: batches.values.sorted { $0.sentAt < $1.sentAt },
                            runs: hub.reviews.compactMap(run))
    }

    /// Every row of a record, for a first upload.
    public static func everything(_ record: ReviewRecord, conversationID: String) -> ReviewBatchRequest {
        let batches = batchesByComment(record)
        return ReviewBatchRequest(
            reviews: record.runs.map { review($0, conversationID: conversationID) },
            items: record.comments.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { item($0, conversationID: conversationID, batch: batches[$0.id]) }
        )
    }

    // MARK: Changes

    /// What a local change touched, by id: rows to write again and rows to delete.
    public struct Touched: Codable, Equatable, Sendable {
        public var items: Set<UUID> = []
        public var runs: Set<UUID> = []
        public var deletedItems: Set<UUID> = []

        public init(items: Set<UUID> = [], runs: Set<UUID> = [], deletedItems: Set<UUID> = []) {
            self.items = items
            self.runs = runs
            self.deletedItems = deletedItems
        }

        public var isEmpty: Bool { items.isEmpty && runs.isEmpty && deletedItems.isEmpty }

        public mutating func merge(_ other: Touched) {
            items.formUnion(other.items)
            runs.formUnion(other.runs)
            deletedItems.formUnion(other.deletedItems)
            items.subtract(other.deletedItems)
            deletedItems.subtract(other.items)
        }
    }

    /// The rows that differ between two versions of a record (a new batch touches its items).
    public static func touched(from old: ReviewRecord, to new: ReviewRecord) -> Touched {
        let oldBatches = batchesByComment(old)
        let newBatches = batchesByComment(new)
        let oldComments = Dictionary(old.comments.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let newComments = Dictionary(new.comments.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var touched = Touched()
        for (id, comment) in newComments where oldComments[id] != comment || oldBatches[id] != newBatches[id] {
            touched.items.insert(id)
        }
        touched.deletedItems = Set(oldComments.keys).subtracting(newComments.keys)
        let oldRuns = Dictionary(old.runs.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for run in new.runs where oldRuns[run.id] != run {
            touched.runs.insert(run.id)
        }
        return touched
    }

    /// The batch request that writes `touched` rows as they are in `record`.
    public static func request(_ touched: Touched, in record: ReviewRecord, conversationID: String) -> ReviewBatchRequest {
        let batches = batchesByComment(record)
        return ReviewBatchRequest(
            reviews: record.runs.filter { touched.runs.contains($0.id) }.map { review($0, conversationID: conversationID) },
            items: record.comments.filter { touched.items.contains($0.id) }
                .map { item($0, conversationID: conversationID, batch: batches[$0.id]) },
            deleteItems: touched.deletedItems.map(\.uuidString).sorted()
        )
    }

    /// Hub rows with local changes not pushed yet laid over them: those stay as they are here.
    public static func merge(hub: ReviewRecord, local: ReviewRecord, pending: Touched) -> ReviewRecord {
        guard !pending.isEmpty else { return hub }
        var merged = hub
        let localComments = Dictionary(local.comments.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        merged.comments.removeAll { pending.items.contains($0.id) || pending.deletedItems.contains($0.id) }
        merged.comments += pending.items.compactMap { localComments[$0] }.sorted { $0.createdAt < $1.createdAt }
        let localRuns = Dictionary(local.runs.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        merged.runs.removeAll { pending.runs.contains($0.id) }
        merged.runs += pending.runs.compactMap { localRuns[$0] }
        merged.runs.sort { $0.startedAt < $1.startedAt }
        // Batches of pending items come from here: the hub may not have them, or not all
        // their items yet.
        for batch in local.batches {
            let pendingMembers = batch.commentIDs.filter(pending.items.contains)
            guard !pendingMembers.isEmpty else { continue }
            if let index = merged.batches.firstIndex(where: { $0.id == batch.id }) {
                for id in pendingMembers where !merged.batches[index].commentIDs.contains(id) {
                    merged.batches[index].commentIDs.append(id)
                }
            } else {
                merged.batches.append(batch)
            }
        }
        merged.batches.sort { $0.sentAt < $1.sentAt }
        return merged
    }

    private static func batchesByComment(_ record: ReviewRecord) -> [UUID: ReviewBatch] {
        var byComment: [UUID: ReviewBatch] = [:]
        for batch in record.batches {
            for id in batch.commentIDs { byComment[id] = batch }
        }
        return byComment
    }
}
