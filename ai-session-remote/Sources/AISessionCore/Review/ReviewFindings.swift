import Foundation

/// Tokens and cost of one reviewer run, as far as its tool reports them.
public struct ReviewUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var costUSD: Double?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens", outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens", cacheWriteTokens = "cache_write_tokens"
        case costUSD = "cost_usd"
    }

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil,
                cacheWriteTokens: Int? = nil, costUSD: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
    }

    /// `12.3k in · 1.2k out · $0.42`
    public var summary: String {
        var parts: [String] = []
        let input = (inputTokens ?? 0) + (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0)
        if input > 0 { parts.append("\(Self.compact(input)) in") }
        if let outputTokens { parts.append("\(Self.compact(outputTokens)) out") }
        if let costUSD { parts.append(String(format: "$%.2f", costUSD)) }
        return parts.joined(separator: " · ")
    }

    static func compact(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)"
    }
}

/// One finding in `ai-todo-review result`. Lines and quote come from git, not the model.
public struct ReviewFinding: Codable, Equatable, Sendable {
    public var path: String
    public var side: DiffSide
    public var lineStart: Int?
    public var lineEnd: Int?
    public var severity: String
    public var category: String
    public var title: String
    public var body: String
    public var quote: [String]
    public var fingerprint: String

    private enum CodingKeys: String, CodingKey {
        case path, side, severity, category, title, body, quote, fingerprint
        case lineStart = "line_start", lineEnd = "line_end"
    }

    public init(path: String, side: DiffSide = .new, lineStart: Int?, lineEnd: Int?, severity: String = "medium",
                category: String = "correctness", title: String, body: String, quote: [String] = [], fingerprint: String) {
        self.path = path
        self.side = side
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.severity = severity
        self.category = category
        self.title = title
        self.body = body
        self.quote = quote
        self.fingerprint = fingerprint
    }
}

/// `ai-todo-review result`: a run's state, and its findings once done.
public struct ReviewRunResult: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case running, done, failed, cancelled
    }

    public struct Output: Codable, Equatable, Sendable {
        public var tool: String
        public var model: String?
        public var from: String
        public var to: String
        public var summary: String
        public var usage: ReviewUsage?
        public var findings: [ReviewFinding]

        public init(tool: String, model: String?, from: String, to: String, summary: String,
                    usage: ReviewUsage?, findings: [ReviewFinding]) {
            self.tool = tool
            self.model = model
            self.from = from
            self.to = to
            self.summary = summary
            self.usage = usage
            self.findings = findings
        }
    }

    public var id: String
    public var state: State
    public var error: String?
    public var result: Output?

    public init(id: String, state: State, error: String? = nil, result: Output? = nil) {
        self.id = id
        self.state = state
        self.error = error
        self.result = result
    }
}

/// One reviewer run, kept with the conversation's comments.
public struct ReviewRun: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// `claude` or `codex`.
    public var tool: String
    public var model: String?
    /// The scope it reviewed (`ReviewScope.rawValue`).
    public var scope: String
    public var baseSHA: String
    /// The revision it read; its findings' lines are in this one.
    public var reviewedSHA: String
    public var state: ReviewRunResult.State
    public var startedAt: Date
    public var finishedAt: Date?
    public var summary: String?
    public var error: String?
    public var usage: ReviewUsage?
    /// Findings it reported, and how many of them were new (not already listed).
    public var findingCount: Int?
    public var addedCount: Int?

    public init(id: UUID = UUID(), tool: String, model: String? = nil, scope: String, baseSHA: String,
                reviewedSHA: String, state: ReviewRunResult.State = .running, startedAt: Date = .now,
                finishedAt: Date? = nil, summary: String? = nil, error: String? = nil, usage: ReviewUsage? = nil,
                findingCount: Int? = nil, addedCount: Int? = nil) {
        self.id = id
        self.tool = tool
        self.model = model
        self.scope = scope
        self.baseSHA = baseSHA
        self.reviewedSHA = reviewedSHA
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.error = error
        self.usage = usage
        self.findingCount = findingCount
        self.addedCount = addedCount
    }

    /// The id the host knows the run by (lowercase, as `ai-todo-review` accepts).
    public var hostID: String { id.uuidString.lowercased() }
}

/// Turning a reviewer's findings into review comments.
public enum ReviewFindings {
    public static let authorPrefix = "reviewer:"

    /// The comments for the findings no existing comment already has (by fingerprint, whatever
    /// its state: one sent or dismissed earlier doesn't come back). New-side lines are in
    /// `output.to`, removed lines in `output.from`.
    public static func comments(from output: ReviewRunResult.Output, runID: UUID, existing: [ReviewComment],
                                at date: Date = .now) -> [ReviewComment] {
        var known = Set(existing.compactMap(\.fingerprint))
        var added: [ReviewComment] = []
        for finding in output.findings where !known.contains(finding.fingerprint) {
            known.insert(finding.fingerprint)
            let end = finding.lineEnd.flatMap { $0 == finding.lineStart ? nil : $0 }
            added.append(ReviewComment(
                author: authorPrefix + output.tool, path: finding.path, side: finding.side,
                startLine: finding.lineStart, endLine: finding.lineStart == nil ? nil : end,
                revision: finding.side == .old ? output.from : output.to, quote: finding.quote,
                body: finding.body, state: .new, createdAt: date, severity: finding.severity,
                category: finding.category, title: finding.title, fingerprint: finding.fingerprint, runID: runID
            ))
        }
        return added
    }

    /// Highest first.
    public static func rank(_ severity: String?) -> Int {
        switch severity {
        case "high": 0
        case "medium": 1
        case "low": 2
        default: 3
        }
    }
}
