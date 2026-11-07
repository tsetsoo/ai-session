import AISessionCore
import Foundation

/// Restarting one conversation on its computer (`ai-todo-status restart` over SSH), and its
/// saved launch settings. Only on the user's request.
enum RemoteRestart {
    /// The computer's scripts predate restart: the caller falls back to ending tmux.
    struct OldScripts: LocalizedError {
        let computer: String
        var errorDescription: String? {
            "The todo scripts on \(computer) are too old for this. Run scripts/todo/install.sh there."
        }
    }

    struct Failed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Refused and failed come back as results (with the computer's message), not errors.
    static func restart(
        _ conversation: Conversation, config: HostConnectionConfig, force: Bool = false,
        chrome: ChromeChoice = .keep, reopen: Bool = false
    ) async throws -> RestartResult {
        // Reopening passes the conversation's own worktree, so one deleted since is made again.
        // Scripts from before that answer 64 for it: those retry without it.
        let worktree = reopen ? conversation.worktree : nil
        var result = try await exec(conversation, config: config, force: force, chrome: chrome, reopen: reopen, worktree: worktree)
        if result.exitCode == 64, worktree != nil {
            result = try await exec(conversation, config: config, force: force, chrome: chrome, reopen: reopen, worktree: nil)
        }
        if result.exitCode == TmuxCommandBuilder.scriptMissingExitCode || result.exitCode == 64 {
            throw OldScripts(computer: conversation.computer.name)
        }
        if let decoded = try? RestartResult.decode(Data(result.stdout.utf8)) {
            return decoded
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw Failed(message: detail.isEmpty ? "The restart failed (exit \(result.exitCode))." : String(detail.prefix(300)))
    }

    private static func exec(
        _ conversation: Conversation, config: HostConnectionConfig, force: Bool, chrome: ChromeChoice, reopen: Bool,
        worktree: (folder: String, branch: String)?
    ) async throws -> SSHExecResult {
        let command = TmuxCommandBuilder.restartConversation(
            tmuxName: conversation.tmuxName, sessionId: conversation.sessionId, tool: conversation.tool,
            force: force, chrome: chrome, reopenCwd: reopen ? conversation.cwd : nil,
            mcpServers: reopen ? conversation.mcpServers : nil, worktree: worktree
        )
        // Stop (10 s at most), the writer lock (10 s), and a reopen (90 s; making a worktree is in it).
        return try await NIOSSHClient(execTimeoutSeconds: 150).exec(config, command: command)
    }

    /// nil when the computer's scripts predate launch settings.
    static func settings(_ conversation: Conversation, config: HostConnectionConfig) async throws -> LaunchSettings? {
        let result = try await NIOSSHClient(execTimeoutSeconds: 20).exec(
            config, command: TmuxCommandBuilder.launchSettings(tool: conversation.tool, sessionId: conversation.sessionId))
        guard result.exitCode == 0 else { return nil }
        return try? LaunchSettings.decode(Data(result.stdout.utf8))
    }

    /// A one-line summary of a done restart, e.g. "Restarted on 2.1.319 (was 2.1.310)."
    static func summary(_ result: RestartResult) -> String {
        switch (result.after, result.before) {
        case let (after?, before?) where after != before: "Restarted on \(after) (was \(before))."
        case let (after?, _): "Restarted on \(after)."
        default: "Restarted."
        }
    }
}
