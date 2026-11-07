import Foundation

/// `ai-todo-review` on the conversation's computer. 127 when the helper isn't installed.
extension TmuxCommandBuilder {
    private static let reviewHelper = "\"$HOME/.ai-remote/bin/ai-todo-review\""

    /// Exit status of `send` while the pane can't take a paste yet (the tool is starting).
    public static let reviewNotReadyExitCode: Int32 = 75
    /// Exit status of `send` when the conversation's tmux session isn't running.
    public static let reviewNoSessionExitCode: Int32 = 66
    /// Not a git repository, or the folder is gone.
    public static let reviewNoRepositoryExitCode: Int32 = 69
    /// A revision that isn't in the repository (any more), or an empty message.
    public static let reviewUnknownRevisionExitCode: Int32 = 65
    /// git itself failed; its message is on stderr.
    public static let reviewGitFailedExitCode: Int32 = 70
    /// git, tmux, or the reviewer's tool (`claude not found`) isn't installed.
    public static let reviewMissingProgramExitCode: Int32 = 90

    /// `ref`: review that branch of the repository instead of its working tree.
    public static func reviewStatus(cwd: String, ref: String? = nil) -> String {
        wrap("exec \(reviewHelper) status \(shellQuotePath(cwd))" + refFlag(ref))
    }

    private static func refFlag(_ ref: String?) -> String {
        ref.map { " --ref \(shellQuote($0))" } ?? ""
    }

    public static func reviewDiff(cwd: String, scope: ReviewScope, from: String? = nil, to: String? = nil,
                                  unified: Int? = nil, ref: String? = nil) -> String {
        var command = "exec \(reviewHelper) diff \(shellQuotePath(cwd)) --scope \(scope.scriptScope)"
        if let from { command += " --from \(shellQuote(from))" }
        if let to { command += " --to \(shellQuote(to))" }
        if let unified { command += " --unified \(max(0, unified))" }
        return wrap(command + refFlag(ref))
    }

    /// Recent commits, and with `before` (ISO 8601) the last one made before then.
    public static func reviewLog(cwd: String, limit: Int = 30, before: String? = nil, ref: String? = nil) -> String {
        var command = "exec \(reviewHelper) log \(shellQuotePath(cwd)) --limit \(min(max(limit, 1), 500))"
        if let before { command += " --before \(shellQuote(before))" }
        return wrap(command + refFlag(ref))
    }

    public static func reviewKeep(cwd: String, revision: String) -> String {
        wrap("exec \(reviewHelper) keep \(shellQuotePath(cwd)) \(shellQuote(revision))")
    }

    /// The message travels base64-encoded, so no byte of it is ever shell syntax. The helper
    /// decodes it itself: `base64 -d` vs `-D` differs between hosts.
    public static func reviewSend(tmuxName: String, message: String) -> String {
        let encoded = Data(message.utf8).base64EncodedString()
        return wrap("printf '%s' \(shellQuote(encoded)) | \(reviewHelper) send --base64 \(shellQuote(tmuxName))")
    }

    /// Starts a reviewer agent on `from`..`to`, detached; `reviewResult` reads how it went.
    /// The brief (the todo's title and notes) travels base64-encoded on stdin, like `send`.
    public static func reviewRun(cwd: String, from: String, to: String, tool: String, id: String,
                                 ref: String? = nil, model: String? = nil, context: [String] = [],
                                 brief: String? = nil) -> String {
        var command = "\(reviewHelper) run \(shellQuotePath(cwd)) --from \(shellQuote(from)) --to \(shellQuote(to))"
            + " --tool \(shellQuote(tool)) --id \(shellQuote(id))" + refFlag(ref)
        if let model { command += " --model \(shellQuote(model))" }
        for path in context { command += " --context \(shellQuotePath(path))" }
        if let brief, !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let encoded = Data(brief.utf8).base64EncodedString()
            return wrap("printf '%s' \(shellQuote(encoded)) | \(command) --brief-base64")
        }
        return wrap("exec \(command) </dev/null")
    }

    public static func reviewResult(id: String) -> String {
        wrap("exec \(reviewHelper) result \(shellQuote(id))")
    }

    public static func reviewCancel(id: String) -> String {
        wrap("exec \(reviewHelper) cancel \(shellQuote(id))")
    }

    /// The repository's worktrees; `since` (ISO 8601) marks those active after it.
    public static func reviewWorktrees(cwd: String, since: String?) -> String {
        wrap("exec \(reviewHelper) worktrees \(shellQuotePath(cwd))" + (since.map { " --since \(shellQuote($0))" } ?? ""))
    }
}
