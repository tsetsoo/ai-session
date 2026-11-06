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

    public static func reviewStatus(cwd: String) -> String {
        wrap("exec \(reviewHelper) status \(shellQuotePath(cwd))")
    }

    public static func reviewDiff(cwd: String, scope: ReviewScope, from: String? = nil, to: String? = nil,
                                  unified: Int? = nil) -> String {
        var command = "exec \(reviewHelper) diff \(shellQuotePath(cwd)) --scope \(scope.rawValue)"
        if let from { command += " --from \(shellQuote(from))" }
        if let to { command += " --to \(shellQuote(to))" }
        if let unified { command += " --unified \(max(0, unified))" }
        return wrap(command)
    }

    public static func reviewKeep(cwd: String, revision: String) -> String {
        wrap("exec \(reviewHelper) keep \(shellQuotePath(cwd)) \(shellQuote(revision))")
    }

    /// The message travels base64-encoded, so no byte of it is ever shell syntax.
    public static func reviewSend(tmuxName: String, message: String) -> String {
        let encoded = Data(message.utf8).base64EncodedString()
        return wrap("printf '%s' \(shellQuote(encoded)) | base64 -d | \(reviewHelper) send \(shellQuote(tmuxName))")
    }
}
