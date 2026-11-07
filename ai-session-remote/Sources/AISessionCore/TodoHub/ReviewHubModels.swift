import Foundation

// The hub's reviews (`/api/reviews`, schema v29). Keys are snake_case on the wire; the
// client's coders convert them, so these types use plain camelCase names.

public struct HubReviewUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var costUsd: Double?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil,
                cacheWriteTokens: Int? = nil, costUsd: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUsd = costUsd
    }
}

/// A reviewer run as the hub keeps it.
public struct HubReview: Codable, Equatable, Sendable {
    public var id: String
    public var conversationId: String
    public var tool: String
    public var model: String?
    public var scope: String
    public var baseSha: String
    public var reviewedSha: String
    public var state: String
    public var startedAt: String
    public var finishedAt: String?
    public var summary: String?
    public var error: String?
    public var usage: HubReviewUsage?
    public var findingCount: Int?
    public var addedCount: Int?
    /// Set by the hub; empty in what the app sends.
    public var createdAt: String?
    public var updatedAt: String?

    public init(id: String, conversationId: String, tool: String, model: String?, scope: String, baseSha: String,
                reviewedSha: String, state: String, startedAt: String, finishedAt: String?, summary: String?,
                error: String?, usage: HubReviewUsage?, findingCount: Int?, addedCount: Int?,
                createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.tool = tool
        self.model = model
        self.scope = scope
        self.baseSha = baseSha
        self.reviewedSha = reviewedSha
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.error = error
        self.usage = usage
        self.findingCount = findingCount
        self.addedCount = addedCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A review comment or finding as the hub keeps it.
public struct HubReviewItem: Codable, Equatable, Sendable {
    public var id: String
    public var reviewId: String?
    public var conversationId: String
    public var author: String
    public var fingerprint: String?
    public var severity: String?
    public var category: String?
    public var title: String?
    public var path: String
    public var side: String
    public var lineStart: Int?
    public var lineEnd: Int?
    public var revision: String
    public var quote: [String]
    public var body: String
    /// `new`, `draft`, `sent`, `addressed`, `stale` or `dismissed`.
    public var state: String
    public var sentAt: String?
    public var sentInTurn: Int?
    public var batchId: String?
    public var sentRevision: String?
    /// When it was posted on the PR/MR.
    public var publishedAt: String?
    public var createdAt: String
    /// Set by the hub.
    public var updatedAt: String?

    public init(id: String, reviewId: String?, conversationId: String, author: String, fingerprint: String?,
                severity: String?, category: String?, title: String?, path: String, side: String, lineStart: Int?,
                lineEnd: Int?, revision: String, quote: [String], body: String, state: String, sentAt: String?,
                sentInTurn: Int?, batchId: String?, sentRevision: String?, publishedAt: String? = nil, createdAt: String,
                updatedAt: String? = nil) {
        self.id = id
        self.reviewId = reviewId
        self.conversationId = conversationId
        self.author = author
        self.fingerprint = fingerprint
        self.severity = severity
        self.category = category
        self.title = title
        self.path = path
        self.side = side
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.revision = revision
        self.quote = quote
        self.body = body
        self.state = state
        self.sentAt = sentAt
        self.sentInTurn = sentInTurn
        self.batchId = batchId
        self.sentRevision = sentRevision
        self.publishedAt = publishedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// `GET /api/reviews?conversation_id=`.
public struct HubReviewRecord: Codable, Equatable, Sendable {
    public var reviews: [HubReview]
    public var items: [HubReviewItem]

    public init(reviews: [HubReview] = [], items: [HubReviewItem] = []) {
        self.reviews = reviews
        self.items = items
    }
}

/// `POST /api/reviews/batch`: whole rows upserted by id, and deletions, all or nothing.
public struct ReviewBatchRequest: Codable, Equatable, Sendable {
    public var reviews: [HubReview]
    public var items: [HubReviewItem]
    public var deleteReviews: [String]
    public var deleteItems: [String]

    public init(reviews: [HubReview] = [], items: [HubReviewItem] = [], deleteReviews: [String] = [], deleteItems: [String] = []) {
        self.reviews = reviews
        self.items = items
        self.deleteReviews = deleteReviews
        self.deleteItems = deleteItems
    }

    public var isEmpty: Bool { reviews.isEmpty && items.isEmpty && deleteReviews.isEmpty && deleteItems.isEmpty }
}

/// `PATCH /api/review-items/{id}`.
public struct UpdateReviewItemRequest: Codable, Equatable, Sendable {
    public var state: String?
    public var body: String?
    public var sentAt: String?
    public var sentInTurn: Int?
    public var batchId: String?
    public var sentRevision: String?
    /// Applied only while the item is still in this state; else the hub answers 409.
    public var expectedState: String?
    /// Clears what a send set (sent at, batch, turn, revision): a send that didn't go out.
    public var clearSent: Bool?

    public init(state: String? = nil, body: String? = nil, sentAt: String? = nil, sentInTurn: Int? = nil,
                batchId: String? = nil, sentRevision: String? = nil, expectedState: String? = nil, clearSent: Bool? = nil) {
        self.state = state
        self.body = body
        self.sentAt = sentAt
        self.sentInTurn = sentInTurn
        self.batchId = batchId
        self.sentRevision = sentRevision
        self.expectedState = expectedState
        self.clearSent = clearSent
    }
}

/// A conversation's review at a glance (`GET /api/reviews/summary`), for its row.
public struct ReviewSummary: Codable, Equatable, Sendable {
    public var conversationId: String
    /// Comments and findings not sent or dismissed yet.
    public var open: Int
    public var reviewing: Bool
    /// When the last finished review started, ISO 8601.
    public var lastReviewedAt: String?

    public init(conversationId: String, open: Int, reviewing: Bool, lastReviewedAt: String?) {
        self.conversationId = conversationId
        self.open = open
        self.reviewing = reviewing
        self.lastReviewedAt = lastReviewedAt
    }

    /// `2 open · reviewed 4m ago`, `reviewing…`, or nil when there's nothing to say.
    public func label(now: Date = .now) -> String? {
        if reviewing { return open > 0 ? "\(open) open · reviewing…" : "reviewing…" }
        var parts: [String] = []
        if open > 0 { parts.append("\(open) open") }
        if let last = lastReviewedAt.flatMap(ReviewSync.date(from:)) {
            parts.append("reviewed \(Self.ago(last, now: now))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}
