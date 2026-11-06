import Foundation

/// The message one batch of review comments becomes in the conversation.
public enum ReviewMessage {
    /// Quoted lines per comment; longer selections end with `> …`.
    public static let maxQuotedLines = 8

    /// - Parameters:
    ///   - branch: the worktree's branch, when it has one.
    ///   - revision: the revision the comments are on now; `includesUncommitted` when it is a snapshot.
    public static func render(_ comments: [ReviewComment], branch: String?, revision: String,
                              includesUncommitted: Bool) -> String {
        let at = [branch.map { "on \($0)" }, "at \(revision.prefix(8))"].compactMap { $0 }.joined(separator: " ")
        let count = comments.count == 1 ? "1 comment" : "\(comments.count) comments"
        let uncommitted = includesUncommitted ? ", including uncommitted changes" : ""
        var parts = ["Review feedback \(at)\(uncommitted) (\(count)). Address each numbered item; "
            + "then reply with what you changed for each number, or why you didn't."]
        for (index, comment) in comments.enumerated() {
            var lines = ["\(index + 1). \(heading(comment))"]
            let quote = comment.quote.prefix(maxQuotedLines).map { "> " + $0 }
            lines += quote
            if comment.quote.count > maxQuotedLines { lines.append("> …") }
            lines.append(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))
            parts.append(lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func heading(_ comment: ReviewComment) -> String {
        if comment.startLine == nil { return "\(comment.path) (whole file)" }
        if comment.side == .old { return "\(comment.location) (removed lines, at \(comment.revision.prefix(8)))" }
        return comment.location
    }
}
